from __future__ import annotations

import unittest

from fastapi.testclient import TestClient

from openai_npu_server import (
    GenerationRequest,
    GenerationResult,
    StreamEvent,
    create_app,
)


class FakeEngine:
    model_id = "fake-ryzen-model"
    

    def health(self):
        return {
            "status": "ok",
            "model_loaded": self.model_id,
            "model": self.model_id,
            "execution_mode": "npu",
            "compatibility_mode": "test-double",
            "provider_libraries": {"RyzenAI": "/tmp/libonnxruntime_providers_ryzenai.so"},
        }

    def list_models(self):
        return [
            {
                "id": self.model_id,
                "object": "model",
                "created": 1,
                "owned_by": "amd",
            }
        ]

    def generate_chat(self, request: GenerationRequest) -> GenerationResult:
        self.last_request = request
        return GenerationResult(
            text="hello from fake engine",
            prompt_tokens=12,
            completion_tokens=4,
            finish_reason="stop",
        )

    def stream_chat(self, request: GenerationRequest):
        self.last_request = request
        yield StreamEvent(kind="role")
        yield StreamEvent(kind="content", text="hello ")
        yield StreamEvent(kind="content", text="stream")
        yield StreamEvent(
            kind="done",
            finish_reason="stop",
            usage={"prompt_tokens": 12, "completion_tokens": 2, "total_tokens": 14},
        )


class OpenAINPUServerTests(unittest.TestCase):
    def setUp(self):
        self.engine = FakeEngine()
        self.client = TestClient(create_app(engine=self.engine))

    def test_health_endpoint(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["model_loaded"], self.engine.model_id)

    def test_models_endpoint(self):
        response = self.client.get("/v1/models")
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["object"], "list")
        self.assertEqual(payload["data"][0]["id"], self.engine.model_id)

    def test_chat_completion(self):
        response = self.client.post(
            "/v1/chat/completions",
            json={
                "model": self.engine.model_id,
                "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": 32,
                "stream": False,
            },
        )
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["model"], self.engine.model_id)
        self.assertEqual(payload["choices"][0]["message"]["content"], "hello from fake engine")
        self.assertEqual(payload["usage"]["total_tokens"], 16)

    def test_streaming_chat_completion(self):
        with self.client.stream(
            "POST",
            "/v1/chat/completions",
            json={
                "model": self.engine.model_id,
                "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": 32,
                "stream": True,
            },
        ) as response:
            self.assertEqual(response.status_code, 200)
            body = "".join(chunk for chunk in response.iter_text())

        self.assertIn('"role": "assistant"', body)
        self.assertIn('"content": "hello "', body)
        self.assertIn('"content": "stream"', body)
        self.assertIn("data: [DONE]", body)


if __name__ == "__main__":
    unittest.main()