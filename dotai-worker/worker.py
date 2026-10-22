"""dot-ai as a KAOP worker, through the bare worker API (no framework adapter).

dot-ai is TypeScript and runs its own agent loop. This wrapper only:
1. asks dot-ai's remediate tool for an analysis and a plan (manual mode, nothing executed),
2. asks a person through KAOP's action permissions to approve that plan,
3. tells dot-ai to execute it only if the person approved.
"""

import os
import uuid

import httpx

from komodor_agentops import AgentOpsWorker, AgentSpec, Run
from komodor_agentops.actions import build_action_gate
from komodor_agentops.core.observe import record_log

DOT_AI_URL = os.environ.get("DOT_AI_URL", "http://dot-ai.dot-ai.svc.cluster.local:3456")
DOT_AI_TOKEN = os.environ["DOT_AI_AUTH_TOKEN"]
# The name the action permission matches; dot-ai's own kubectl calls never pass through KAOP.
EXECUTE_TOOL = "dot_ai_remediate_execute"


async def remediate(client: httpx.AsyncClient, body: dict) -> dict:
    response = await client.post(f"{DOT_AI_URL}/api/v1/tools/remediate", json=body)
    response.raise_for_status()
    return response.json()["data"]["result"]


def plan_text(result: dict) -> str:
    analysis = result.get("analysis", {})
    remediation = result.get("remediation", {})
    lines = [
        f"Root cause: {analysis.get('rootCause', '?')}",
        f"Confidence: {analysis.get('confidence', '?')}",
        f"Plan: {remediation.get('summary', '?')} (risk: {remediation.get('risk', '?')})",
    ]
    for action in remediation.get("actions", []):
        lines.append(f"- {action.get('description', '')}: {action.get('command', '')}")
    return "\n".join(lines)


async def on_run(run: Run) -> dict:
    issue = run.input.get("prompt") or run.input.get("issue") or ""
    async with httpx.AsyncClient(headers={"Authorization": f"Bearer {DOT_AI_TOKEN}"}, timeout=1800) as client:
        analysis = await remediate(client, {"issue": issue, "mode": "manual"})
        plan = plan_text(analysis)
        record_log(run_id=run.run_id, message=f"dot-ai analysis:\n{plan}", level="info")
        if analysis.get("status") != "awaiting_user_approval":
            return {"text": f"dot-ai found nothing to execute.\n\n{plan}", "dot_ai": analysis}

        commands = "\n".join(a.get("command", "") for a in analysis.get("remediation", {}).get("actions", []))
        arguments = {"command": commands, "description": plan}
        gate = build_action_gate(run)
        if gate is not None:
            decision = gate.decide(EXECUTE_TOOL, arguments)
            if decision.needs_approval:
                decision = await gate.resolve(
                    rule=decision.rule,
                    tool_use_id=f"{run.run_id}-{uuid.uuid4().hex[:8]}",
                    tool_name=EXECUTE_TOOL,
                    arguments=arguments,
                    asked_by="dot-ai",
                )
            if not decision.allowed:
                return {"text": f"Not executed: {decision.reason}\n\n{plan}", "dot_ai": analysis}

        executed = await remediate(
            client, {"executeChoice": 1, "sessionId": analysis["sessionId"], "mode": "manual"}
        )
        return {
            "text": f"{plan}\n\nExecuted. Status: {executed.get('status')}\n{executed.get('message', '')}",
            "dot_ai": executed,
        }


def main() -> None:
    spec = AgentSpec(
        agent_id=os.environ["AGENTOPS_AGENT_ID"],
        agent_card={
            "name": "dot-ai",
            "description": "dot-ai (TypeScript) analyses a Kubernetes issue and executes the plan once a person approves it.",
            "skills": [{"id": "remediate", "name": "remediate"}],
        },
    )
    AgentOpsWorker(agent=spec, on_run=on_run).run()


if __name__ == "__main__":
    main()
