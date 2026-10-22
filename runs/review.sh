export PATH=/usr/bin:/bin:/Users/viktorfarcic/code/devops-catalog/.devbox/nix/profile/default/bin
set -e
echo '$ audit'
curl --silent "https://agentops.komodor.com/api/v1/audit?run_id=run_7d2e5f9998fc8624aa74cf01" \
    --header "Authorization: Bearer $AGENTOPS_API_KEY" \
    | jq --compact-output '.[] | {created_at, action, actor: .detail.actor_label, via: .detail.decided_via, basis: .detail.basis, approval: .detail.approval_id}'
echo '$ runcreate'
curl --silent "https://agentops.komodor.com/api/v1/audit?category=run&limit=5" \
    --header "Authorization: Bearer $AGENTOPS_API_KEY" \
    | jq --compact-output '.[] | {created_at, action, actor: .detail.actor_label, run: .detail.run_id, transport: .detail.transport}'
echo '$ approvers'
curl --silent "https://agentops.komodor.com/api/v1/authz/action-permissions/acp_8bd45761b964f2519b249797/approvers" \
    --header "Authorization: Bearer $AGENTOPS_API_KEY"
echo
