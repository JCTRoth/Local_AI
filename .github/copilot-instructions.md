# MCP Tool Usage Guidelines

This workspace includes an MCP kit in `mcpServers-copilot/`. The tracked MCP configuration is copied into `.vscode/mcp.json`, and the configured server names are:

- `chrome-devtools`
- `docker-mcp`
- `google-toolbox`
- `kubernetes`
- `microsoft-learn`

Use these servers whenever the user asks for live data in their domain. Do not invent results when a matching MCP tool exists.

## General Rules

- If a relevant MCP server exists for the request, use it before answering from background knowledge.
- Do not claim data is live unless the MCP call succeeded.
- If a tool fails or a prerequisite is missing, report the exact failure and stop guessing.
- Briefly show which MCP server was used and quote the key raw result before summarizing.
- If no MCP tool covers the topic, answer from knowledge and explicitly say the answer is not based on live data.

## Kubernetes

When the user asks about Kubernetes, pods, deployments, services, ingresses, config maps, secrets, nodes, namespaces, events, logs, or cluster health, ALWAYS use the `kubernetes` MCP server.

- Prefer read-only diagnostics first: `get`, `describe`, `logs`, and events.
- If the namespace is not specified, prefer `default` for read-only checks and say so, or ask the user which namespace to use.
- Never perform destructive or mutating actions without explicit confirmation.
- Warn clearly before acting on a production context.
- Show the equivalent `kubectl` command when possible.
- If `kubectl` or kubeconfig is unavailable, say so explicitly instead of guessing cluster state.

Examples:
- “Why is my app down?” → inspect pod status, deployment status, and recent events.
- “Show me failing pods” → use live cluster data.
- “Scale the API” → ask for confirmation, then use the cluster tool.

## Docker

When the user asks about containers, images, Compose, build output, logs, or running services, ALWAYS use the `docker-mcp` server.

- Use live container and image data instead of assumptions.
- Prefer read-only commands first: container status, image lists, logs, inspect output.
- Ask for confirmation before stopping, removing, pruning, or replacing containers/images.
- If Docker is unavailable on the machine, report that directly.

Examples:
- “What’s running?” → inspect live containers.
- “Show the API logs” → fetch live logs.
- “Build this image” → only after an explicit user request.

## Databases

When the user asks about schemas, tables, SQL queries, counts, rows, indexes, or migrations, ALWAYS use the `google-toolbox` MCP server with the configured database connection.

- Use the configured tool name `my-postgres-db` unless the user specifies another one.
- If the schema is unknown, inspect `information_schema` or `pg_catalog` first.
- Never invent table names, columns, or row counts.
- Never perform `INSERT`, `UPDATE`, `DELETE`, `DROP`, or migrations without explicit confirmation.
- If `tools.yaml` is not configured with working credentials, say so clearly.

Examples:
- “How many users signed up today?” → query live data.
- “What columns are on orders?” → inspect the real schema first.

## Browser and Frontend

When the user asks about a running web app, browser errors, the DOM, screenshots, network issues, performance, or UI regressions, ALWAYS use the `chrome-devtools` MCP server.

- Verify a browser session is available before diagnosing.
- Inspect console errors, network failures, and the current DOM state before speculating.
- Use screenshots or snapshots to confirm visual/UI issues.
- Base frontend debugging on observed browser output, not assumptions.

Examples:
- “Why is the login page blank?” → inspect console and network.
- “Take a screenshot of the dashboard” → use the browser tool.
- “Why is this button disabled?” → inspect the live DOM.

## Microsoft Documentation

When the user asks about Azure, .NET, C#, ASP.NET Core, Entity Framework, .NET MAUI, Visual Studio, Entra, Azure CLI, or Microsoft APIs, ALWAYS use the `microsoft-learn` MCP server first.

- Prefer official documentation over memory.
- Include links to the source documentation in the answer.
- Prefer official samples and current version guidance.
- If official docs are unclear or unavailable, say that before supplementing with general knowledge.

Examples:
- “What’s new in C# 14?” → search Microsoft Learn.
- “How do I configure ASP.NET Core rate limiting?” → fetch official docs first.
- “What’s new in the last MAUI update?” → use Microsoft Learn.

## Safety Guardrails

- Read-only by default.
- Ask for confirmation before destructive or state-changing operations.
- Do not delete Kubernetes resources, remove containers/images, or mutate database data without clear user approval.
- Never hide tool errors; surface them plainly.
- Never fabricate live outputs.

## Output Style

- Name the MCP server you used.
- Quote the most relevant raw result briefly.
- Then summarize the conclusion in plain language.
- If no live result is available, say why.
