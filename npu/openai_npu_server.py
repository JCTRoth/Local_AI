#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator, Protocol

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field


LOGGER = logging.getLogger("openai_npu_server")


class ChatMessage(BaseModel):
    model_config = ConfigDict(extra="allow")

    role: str
    content: Any


class ChatCompletionRequest(BaseModel):
    model_config = ConfigDict(extra="allow")

    model: str | None = None
    messages: list[ChatMessage]
    max_tokens: int = Field(default=512, ge=1, le=32768)
    temperature: float | None = Field(default=None, ge=0.0)
    top_p: float | None = Field(default=None, ge=0.0, le=1.0)
    top_k: int | None = Field(default=None, ge=0)
    repetition_penalty: float | None = Field(default=None, ge=0.0)
    stream: bool = False
    stop: str | list[str] | None = None
    tools: list[dict[str, Any]] | None = None


@dataclass
class GenerationRequest:
    model: str
    messages: list[dict[str, Any]]
    max_tokens: int
    temperature: float | None
    top_p: float | None
    top_k: int | None
    repetition_penalty: float | None
    stop: list[str]
    tools: list[dict[str, Any]] | None

    @classmethod
    def from_chat_request(
        cls,
        request: ChatCompletionRequest,
        default_model: str,
    ) -> "GenerationRequest":
        stop = request.stop
        if stop is None:
            stop_list: list[str] = []
        elif isinstance(stop, str):
            stop_list = [stop]
        else:
            stop_list = stop

        return cls(
            model=request.model or default_model,
            messages=[message.model_dump() for message in request.messages],
            max_tokens=request.max_tokens,
            temperature=request.temperature,
            top_p=request.top_p,
            top_k=request.top_k,
            repetition_penalty=request.repetition_penalty,
            stop=stop_list,
            tools=request.tools,
        )


@dataclass
class GenerationResult:
    text: str
    prompt_tokens: int
    completion_tokens: int
    finish_reason: str


@dataclass
class StreamEvent:
    kind: str
    text: str = ""
    role: str = "assistant"
    finish_reason: str = "stop"
    usage: dict[str, int] | None = None


@dataclass
class ServerSettings:
    model_path: str
    model_name: str | None = None
    host: str = "127.0.0.1"
    port: int = 8080
    log_level: str = "info"
    ryzen_ai_root: str = "/opt/ryzen_ai"
    provider_library: str | None = None
    check_only: bool = False

    @classmethod
    def from_args(cls, args: argparse.Namespace) -> "ServerSettings":
        return cls(
            model_path=args.model_path,
            model_name=args.model_name,
            host=args.host,
            port=args.port,
            log_level=args.log_level,
            ryzen_ai_root=args.ryzen_ai_root,
            provider_library=args.provider_library,
            check_only=args.check_only,
        )


class ChatEngine(Protocol):
    model_id: str

    def health(self) -> dict[str, Any]:
        ...

    def list_models(self) -> list[dict[str, Any]]:
        ...

    def generate_chat(self, request: GenerationRequest) -> GenerationResult:
        ...

    def stream_chat(self, request: GenerationRequest) -> Iterator[StreamEvent]:
        ...


class RuntimeCompatibilityError(RuntimeError):
    pass


class ModelLoadError(RuntimeError):
    pass


class GenAIChatEngine:
    def __init__(self, settings: ServerSettings) -> None:
        self.settings = settings
        self.model_dir = self._resolve_model_dir(settings.model_path)
        self.model_id = settings.model_name or self.model_dir.name
        self.config_path = self.model_dir / "genai_config.json"
        self.config_data = self._load_json(self.config_path)
        self.chat_template = self._load_chat_template()
        self.search_defaults = self._load_search_defaults()
        self.execution_mode = self._detect_execution_mode()
        self.compatibility_mode = "follow_config"
        self.registered_provider_libraries: dict[str, str] = {}
        self.model: Any = None
        self.tokenizer: Any = None
        self.og: Any = None

    def load(self) -> None:
        if self.model is not None and self.tokenizer is not None:
            return

        self.og = self._import_og()
        self._register_provider_libraries()

        direct_error: Exception | None = None
        try:
            self.model = self.og.Model(str(self.model_dir))
            self.compatibility_mode = "follow_config"
        except Exception as exc:  # pragma: no cover - exercised by live runtime check
            direct_error = exc
            if not self._looks_like_provider_name_error(exc):
                raise self._rewrite_model_error(exc) from exc

        if self.model is None:
            try:
                self.model = self._load_with_provider_override("VitisAI")
                self.compatibility_mode = "provider_override:VitisAI"
            except Exception as compat_exc:  # pragma: no cover - exercised by live runtime check
                raise self._rewrite_model_error(compat_exc, direct_error) from compat_exc

        try:
            self.tokenizer = self.og.Tokenizer(self.model)
        except Exception as exc:  # pragma: no cover - exercised by live runtime check
            raise ModelLoadError(f"Tokenizer initialization failed: {exc}") from exc

    def health(self) -> dict[str, Any]:
        return {
            "status": "ok",
            "model_loaded": self.model_id,
            "model": self.model_id,
            "model_path": str(self.model_dir),
            "execution_mode": self.execution_mode,
            "compatibility_mode": self.compatibility_mode,
            "provider_libraries": self.registered_provider_libraries,
        }

    def list_models(self) -> list[dict[str, Any]]:
        return [
            {
                "id": self.model_id,
                "object": "model",
                "created": int(time.time()),
                "owned_by": "amd",
            }
        ]

    def generate_chat(self, request: GenerationRequest) -> GenerationResult:
        prompt = self._build_prompt(request.messages, request.tools)
        prompt_tokens, output_text, completion_tokens, finish_reason = self._generate_text(
            prompt,
            request,
        )
        return GenerationResult(
            text=output_text,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            finish_reason=finish_reason,
        )

    def stream_chat(self, request: GenerationRequest) -> Iterator[StreamEvent]:
        prompt = self._build_prompt(request.messages, request.tools)
        generator, prompt_tokens = self._create_generator(prompt, request)
        tokenizer_stream = self.tokenizer.create_stream()
        emitted_text = ""
        buffered_text = ""
        completion_tokens = 0
        finish_reason = "stop"

        yield StreamEvent(kind="role")

        try:
            while not generator.is_done():
                generator.generate_next_token()
                for token in self._iter_tokens(generator.get_next_tokens()):
                    completion_tokens += 1
                    decoded = tokenizer_stream.decode(int(token))
                    if decoded:
                        buffered_text += decoded

                    limited_text, stop_hit = self._apply_stop_sequences(buffered_text, request.stop)
                    if len(limited_text) > len(emitted_text):
                        delta = limited_text[len(emitted_text) :]
                        emitted_text = limited_text
                        if delta:
                            yield StreamEvent(kind="content", text=delta)

                    if stop_hit:
                        finish_reason = "stop"
                        usage = self._usage(prompt_tokens, completion_tokens)
                        yield StreamEvent(kind="done", finish_reason=finish_reason, usage=usage)
                        return

                    if completion_tokens >= request.max_tokens:
                        finish_reason = "length"
                        usage = self._usage(prompt_tokens, completion_tokens)
                        yield StreamEvent(kind="done", finish_reason=finish_reason, usage=usage)
                        return
        finally:
            del generator

        if len(buffered_text) > len(emitted_text):
            yield StreamEvent(kind="content", text=buffered_text[len(emitted_text) :])

        usage = self._usage(prompt_tokens, completion_tokens)
        yield StreamEvent(kind="done", finish_reason=finish_reason, usage=usage)

    def _resolve_model_dir(self, raw_path: str) -> Path:
        path = Path(raw_path).expanduser().resolve()
        if path.is_dir():
            return path
        if path.name == "genai_config.json":
            return path.parent
        raise ModelLoadError(f"MODEL_PATH must point to a model directory or genai_config.json: {path}")

    def _load_json(self, path: Path) -> dict[str, Any]:
        if not path.is_file():
            raise ModelLoadError(f"Required file not found: {path}")
        return json.loads(path.read_text(encoding="utf-8"))

    def _load_chat_template(self) -> str:
        jinja_path = self.model_dir / "chat_template.jinja"
        if jinja_path.is_file():
            return jinja_path.read_text(encoding="utf-8")

        tokenizer_config = self.model_dir / "tokenizer_config.json"
        if tokenizer_config.is_file():
            try:
                data = self._load_json(tokenizer_config)
                template = data.get("chat_template")
                if isinstance(template, str):
                    return template
            except Exception:
                return ""

        return ""

    def _load_search_defaults(self) -> dict[str, Any]:
        search = self.config_data.get("search", {})
        defaults = {
            "batch_size": 1,
            "do_sample": bool(search.get("do_sample", True)),
            "temperature": float(search.get("temperature", 0.7)),
            "top_p": float(search.get("top_p", 0.8)),
            "top_k": int(search.get("top_k", 20)),
            "repetition_penalty": float(search.get("repetition_penalty", 1.0)),
        }
        return defaults

    def _detect_execution_mode(self) -> str:
        session_options = (
            self.config_data.get("model", {})
            .get("decoder", {})
            .get("session_options", {})
        )

        config_entries = session_options.get("config_entries", {})
        if config_entries.get("hybrid_opt_token_backend") == "npu":
            return "npu"

        provider_options = session_options.get("provider_options", [])
        for provider in provider_options:
            if not isinstance(provider, dict):
                continue
            if "RyzenAI" in provider:
                ryzen_ai = provider["RyzenAI"]
                if isinstance(ryzen_ai, dict) and ryzen_ai.get("hybrid_opt_token_backend") == "npu":
                    return "npu"
                return "hybrid"
            if "VitisAI" in provider:
                vitis_ai = provider["VitisAI"]
                if isinstance(vitis_ai, dict) and vitis_ai.get("hybrid_opt_token_backend") == "npu":
                    return "npu"
                return "hybrid"

        return "cpu"

    def _import_og(self) -> Any:
        try:
            import onnxruntime_genai as og  # type: ignore
        except ImportError as exc:  # pragma: no cover - depends on host runtime
            raise ModelLoadError(
                "onnxruntime_genai is not importable. Use the Ryzen AI Python environment or run setup_openai_npu_server.sh."
            ) from exc
        return og

    def _candidate_provider_paths(self) -> dict[str, list[str]]:
        candidates = {
            "RyzenAI": [],
            "VitisAI": [],
        }

        if self.settings.provider_library:
            candidates["RyzenAI"].append(self.settings.provider_library)

        env_provider = os.getenv("RYZENAI_EP_PATH")
        if env_provider:
            candidates["RyzenAI"].append(env_provider)

        roots = [
            self.settings.ryzen_ai_root,
            os.getenv("RYZENAI_INSTALLATION_PATH", ""),
            os.getenv("RYZENAI_INSTALL_PATH", ""),
            str(Path.home() / "ryzen_ai_env"),
        ]

        for root in roots:
            if not root:
                continue
            site_packages = Path(root) / "lib/python3.12/site-packages"
            candidates["RyzenAI"].append(
                str(site_packages / "onnxruntime/capi/libonnxruntime_providers_ryzenai.so")
            )
            candidates["VitisAI"].append(
                str(site_packages / "onnxruntime/capi/libonnxruntime_providers_vitisai.so")
            )

        return candidates

    def _register_provider_libraries(self) -> None:
        register = getattr(self.og, "register_execution_provider_library", None)
        if register is None:
            return

        candidates = self._candidate_provider_paths()
        for alias, paths in candidates.items():
            for path in paths:
                if not path:
                    continue
                library = Path(path)
                if not library.is_file():
                    continue
                if alias in self.registered_provider_libraries:
                    break
                try:
                    register(alias, str(library))
                    self.registered_provider_libraries[alias] = str(library)
                except Exception as exc:  # pragma: no cover - depends on host runtime
                    LOGGER.debug("Provider registration failed for %s at %s: %s", alias, library, exc)

    def _provider_options_for(self, *provider_names: str) -> dict[str, str]:
        provider_options = (
            self.config_data.get("model", {})
            .get("decoder", {})
            .get("session_options", {})
            .get("provider_options", [])
        )

        for provider in provider_options:
            if not isinstance(provider, dict):
                continue
            for provider_name in provider_names:
                value = provider.get(provider_name)
                if isinstance(value, dict):
                    return {key: str(option) for key, option in value.items()}
        return {}

    def _load_with_provider_override(self, provider_name: str) -> Any:
        config = self.og.Config(str(self.model_dir))
        config.clear_providers()
        config.append_provider(provider_name)

        provider_options = self._provider_options_for("RyzenAI", provider_name)
        for option_name, option_value in provider_options.items():
            config.set_provider_option(provider_name, option_name, option_value)

        return self.og.Model(config)

    def _looks_like_provider_name_error(self, exc: Exception) -> bool:
        return "Unknown provider name 'RyzenAI'" in str(exc)

    def _rewrite_model_error(
        self,
        exc: Exception,
        direct_error: Exception | None = None,
    ) -> RuntimeError:
        message = str(exc)
        if "Unknown provider name 'RyzenAI'" in message:
            detail = (
                "The installed onnxruntime-genai runtime does not recognize the model's RyzenAI provider name. "
                "The server also attempted a VitisAI compatibility override, but the model still could not be loaded."
            )
            if direct_error is not None and str(direct_error) != message:
                detail = f"{detail} Original error: {direct_error}"
            return RuntimeCompatibilityError(detail)

        if "No opset import for domain 'com.ryzenai'" in message:
            return RuntimeCompatibilityError(
                "The installed ONNX Runtime GenAI build cannot register the com.ryzenai custom ops used by this model. "
                "That indicates a runtime/model mismatch on this host. Align the Ryzen AI / OGA build with the model package before expecting NPU inference."
            )

        return ModelLoadError(message)

    def _build_prompt(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None,
    ) -> str:
        normalized_messages = [self._normalize_message(message) for message in messages]
        messages_json = json.dumps(normalized_messages, ensure_ascii=False)
        tools_json = json.dumps(tools, ensure_ascii=False) if tools else ""

        try:
            return self.tokenizer.apply_chat_template(
                template_str=self.chat_template,
                messages=messages_json,
                tools=tools_json,
                add_generation_prompt=True,
            )
        except Exception:
            return self._fallback_prompt(normalized_messages)

    def _normalize_message(self, message: dict[str, Any]) -> dict[str, Any]:
        normalized = dict(message)
        normalized["content"] = self._normalize_content(message.get("content", ""))
        return normalized

    def _normalize_content(self, content: Any) -> str:
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts: list[str] = []
            for item in content:
                if isinstance(item, str):
                    parts.append(item)
                    continue
                if isinstance(item, dict):
                    if item.get("type") == "text" and isinstance(item.get("text"), str):
                        parts.append(item["text"])
                    elif isinstance(item.get("content"), str):
                        parts.append(item["content"])
            return "\n".join(part for part in parts if part)
        if isinstance(content, dict):
            text = content.get("text")
            if isinstance(text, str):
                return text
        return str(content)

    def _fallback_prompt(self, messages: list[dict[str, Any]]) -> str:
        prompt_parts: list[str] = []
        for message in messages:
            role = message.get("role", "user")
            content = message.get("content", "")
            prompt_parts.append(f"<|im_start|>{role}\n{content}<|im_end|>")
        prompt_parts.append("<|im_start|>assistant\n")
        return "\n".join(prompt_parts)

    def _search_options(self, prompt_tokens: int, request: GenerationRequest) -> dict[str, Any]:
        options = dict(self.search_defaults)
        options["max_length"] = prompt_tokens + request.max_tokens
        if request.temperature is not None:
            options["temperature"] = request.temperature
            options["do_sample"] = request.temperature > 0.0
        if request.top_p is not None:
            options["top_p"] = request.top_p
        if request.top_k is not None:
            options["top_k"] = request.top_k
        if request.repetition_penalty is not None:
            options["repetition_penalty"] = request.repetition_penalty
        options["batch_size"] = 1
        return options

    def _create_generator(self, prompt: str, request: GenerationRequest) -> tuple[Any, int]:
        input_tokens = self.tokenizer.encode(prompt)
        prompt_tokens = len(input_tokens)
        params = self.og.GeneratorParams(self.model)
        params.set_search_options(**self._search_options(prompt_tokens, request))
        generator = self.og.Generator(self.model, params)
        generator.append_tokens(input_tokens)
        return generator, prompt_tokens

    def _generate_text(
        self,
        prompt: str,
        request: GenerationRequest,
    ) -> tuple[int, str, int, str]:
        generator, prompt_tokens = self._create_generator(prompt, request)
        tokenizer_stream = self.tokenizer.create_stream()
        buffered_text = ""
        completion_tokens = 0
        finish_reason = "stop"

        try:
            while not generator.is_done():
                generator.generate_next_token()
                for token in self._iter_tokens(generator.get_next_tokens()):
                    completion_tokens += 1
                    decoded = tokenizer_stream.decode(int(token))
                    if decoded:
                        buffered_text += decoded

                    limited_text, stop_hit = self._apply_stop_sequences(buffered_text, request.stop)
                    if stop_hit:
                        return prompt_tokens, limited_text, completion_tokens, "stop"

                    if completion_tokens >= request.max_tokens:
                        finish_reason = "length"
                        return prompt_tokens, limited_text, completion_tokens, finish_reason
        finally:
            del generator

        return prompt_tokens, buffered_text, completion_tokens, finish_reason

    def _iter_tokens(self, tokens: Any) -> Iterator[int]:
        if hasattr(tokens, "tolist"):
            values = tokens.tolist()
        else:
            values = list(tokens)

        if isinstance(values, list):
            for value in values:
                if isinstance(value, list):
                    for nested in value:
                        yield int(nested)
                else:
                    yield int(value)
            return

        yield int(values)

    def _apply_stop_sequences(self, text: str, stop_sequences: list[str]) -> tuple[str, bool]:
        if not stop_sequences:
            return text, False
        cut_index: int | None = None
        for stop in stop_sequences:
            if not stop:
                continue
            index = text.find(stop)
            if index == -1:
                continue
            if cut_index is None or index < cut_index:
                cut_index = index
        if cut_index is None:
            return text, False
        return text[:cut_index], True

    def _usage(self, prompt_tokens: int, completion_tokens: int) -> dict[str, int]:
        return {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
        }


def _get_engine(app: FastAPI) -> ChatEngine:
    engine = getattr(app.state, "engine", None)
    if engine is None:
        raise HTTPException(status_code=500, detail="Model engine is not initialized")
    return engine


def _build_chat_response(result: GenerationResult, request_model: str) -> dict[str, Any]:
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": request_model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": result.text},
                "finish_reason": result.finish_reason,
            }
        ],
        "usage": {
            "prompt_tokens": result.prompt_tokens,
            "completion_tokens": result.completion_tokens,
            "total_tokens": result.prompt_tokens + result.completion_tokens,
        },
    }


def _sse_chunk(
    request_id: str,
    created_at: int,
    model: str,
    *,
    delta: dict[str, Any],
    finish_reason: str | None,
) -> str:
    payload = {
        "id": request_id,
        "object": "chat.completion.chunk",
        "created": created_at,
        "model": model,
        "choices": [
            {
                "index": 0,
                "delta": delta,
                "finish_reason": finish_reason,
            }
        ],
    }
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


def create_app(
    settings: ServerSettings | None = None,
    engine: ChatEngine | None = None,
) -> FastAPI:
    resolved_settings = settings or ServerSettings(
        model_path=os.getenv("MODEL_PATH", ""),
        model_name=os.getenv("MODEL_NAME"),
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if engine is None:
            runtime_engine = GenAIChatEngine(resolved_settings)
            runtime_engine.load()
            app.state.engine = runtime_engine
        else:
            app.state.engine = engine
        yield

    app = FastAPI(title="Ryzen AI OpenAI Server", lifespan=lifespan)
    if engine is not None:
        app.state.engine = engine

    @app.get("/")
    def root() -> dict[str, Any]:
        current_engine = _get_engine(app)
        return {
            "message": "Ryzen AI OpenAI Server",
            "model": current_engine.model_id,
            "endpoints": ["/health", "/v1/models", "/v1/chat/completions"],
        }

    @app.get("/health")
    def health() -> dict[str, Any]:
        return _get_engine(app).health()

    @app.get("/v1/models")
    def list_models() -> dict[str, Any]:
        return {"object": "list", "data": _get_engine(app).list_models()}

    @app.post("/v1/chat/completions")
    def chat_completions(request: ChatCompletionRequest):
        current_engine = _get_engine(app)
        generation_request = GenerationRequest.from_chat_request(request, current_engine.model_id)

        if request.stream:
            request_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
            created_at = int(time.time())
            model_name = generation_request.model

            def event_stream() -> Iterator[str]:
                try:
                    for event in current_engine.stream_chat(generation_request):
                        if event.kind == "role":
                            yield _sse_chunk(
                                request_id,
                                created_at,
                                model_name,
                                delta={"role": event.role},
                                finish_reason=None,
                            )
                        elif event.kind == "content":
                            yield _sse_chunk(
                                request_id,
                                created_at,
                                model_name,
                                delta={"content": event.text},
                                finish_reason=None,
                            )
                        elif event.kind == "done":
                            yield _sse_chunk(
                                request_id,
                                created_at,
                                model_name,
                                delta={},
                                finish_reason=event.finish_reason,
                            )
                            yield "data: [DONE]\n\n"
                except Exception as exc:
                    LOGGER.exception("Streaming generation failed")
                    error_payload = {
                        "error": {
                            "message": str(exc),
                            "type": "runtime_error",
                        }
                    }
                    yield f"data: {json.dumps(error_payload, ensure_ascii=False)}\n\n"
                    yield "data: [DONE]\n\n"

            return StreamingResponse(event_stream(), media_type="text/event-stream")

        try:
            result = current_engine.generate_chat(generation_request)
        except Exception as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc

        return _build_chat_response(result, generation_request.model)

    return app


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="OpenAI-compatible FastAPI server for Ryzen AI GenAI models")
    parser.add_argument(
        "--model-path",
        default=os.getenv("MODEL_PATH", ""),
        help="Path to the model directory or genai_config.json",
    )
    parser.add_argument(
        "--model-name",
        default=os.getenv("MODEL_NAME"),
        help="Model id exposed on /v1/models",
    )
    parser.add_argument("--host", default=os.getenv("HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.getenv("PORT", "8080")))
    parser.add_argument("--log-level", default=os.getenv("LOG_LEVEL", "info"))
    parser.add_argument(
        "--ryzen-ai-root",
        default=os.getenv("RYZENAI_INSTALLATION_PATH") or os.getenv("RYZENAI_INSTALL_PATH") or "/opt/ryzen_ai",
        help="Ryzen AI installation root used for provider library discovery",
    )
    parser.add_argument(
        "--provider-library",
        default=os.getenv("RYZENAI_EP_PATH"),
        help="Optional explicit provider library path",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Validate model loading and print health JSON without starting the HTTP server",
    )
    args = parser.parse_args(argv)

    if not args.model_path:
        parser.error("--model-path or MODEL_PATH is required")

    return args


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="[%(levelname)s] %(asctime)s %(name)s: %(message)s",
    )


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    settings = ServerSettings.from_args(args)
    configure_logging(settings.log_level)

    if settings.check_only:
        try:
            engine = GenAIChatEngine(settings)
            engine.load()
        except Exception as exc:
            LOGGER.error("Model check failed: %s", exc)
            return 1
        print(json.dumps(engine.health(), indent=2))
        return 0

    try:
        import uvicorn
    except ImportError:
        LOGGER.error("uvicorn is not installed. Run setup_openai_npu_server.sh first.")
        return 1

    app = create_app(settings=settings)

    try:
        uvicorn.run(app, host=settings.host, port=settings.port, log_level=settings.log_level)
    except Exception as exc:
        LOGGER.error("Server startup failed: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())