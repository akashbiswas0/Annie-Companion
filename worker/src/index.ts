/**
 * Clicky Proxy Worker
 *
 * Proxies requests to OpenAI APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat  → OpenAI Chat Completions API (streaming)
 *   POST /transcribe → OpenAI audio transcription API
 *   POST /tts   → OpenAI text-to-speech API
 */

interface Env {
  OPENAI_API_KEY: string;
  /** Optional; required only for POST /transcribe-token */
  ASSEMBLYAI_API_KEY?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/" || url.pathname === "/health") {
      if (request.method === "GET") {
        return new Response(
          JSON.stringify({
            service: "clicky-proxy",
            routes: [
              "POST /chat → OpenAI chat completions (SSE)",
              "POST /transcribe → OpenAI audio transcriptions",
              "POST /tts → OpenAI speech",
              "POST /transcribe-token → AssemblyAI streaming token",
            ],
          }),
          {
            status: 200,
            headers: { "content-type": "application/json; charset=utf-8" },
          }
        );
      }
      return new Response("Method not allowed", { status: 405 });
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe") {
        return await handleTranscription(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] OpenAI API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscription(request: Request, env: Env): Promise<Response> {
  const requestBody = await request.arrayBuffer();
  const contentTypeHeader = request.headers.get("content-type") || "application/octet-stream";

  const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": contentTypeHeader,
    },
    body: requestBody,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe] OpenAI transcription error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "application/json",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  if (!env.ASSEMBLYAI_API_KEY) {
    return new Response(
      JSON.stringify({
        error: "AssemblyAI is not configured on this worker",
      }),
      {
        status: 503,
        headers: { "content-type": "application/json; charset=utf-8" },
      }
    );
  }

  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
      accept: "audio/mpeg",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] OpenAI TTS error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
