# Senior SRE Take-Home Exercise

## Overview

Treat this as a **pull request review and fix**. A teammate has opened a PR with the following description:

> **PR Title:** feat: add tenant provisioning module
>
> **Description:**
> This adds the Terraform module we'll use to onboard new tenants to the platform. When we bring a new customer onto the shared EKS cluster, we call this module to create their isolated resources. The module gives a tenant everything their workloads need: a place to store PHI (S3), a session cache (Redis), an identity for their pods (IRSA), encryption (KMS), and network isolation.
>
> **Usage example:**
> ```hcl
> module "tenant_acme_health" {
>   source = "./modules/tenant-provisioning"
>
>   tenant_name                = "acme-health"
>   environment                = "production"
>   cluster_name               = "shared-platform-usw2"
>   oidc_provider_arn          = data.aws_eks_cluster.main.identity[0].oidc[0].issuer
>   vpc_id                     = module.vpc.vpc_id
>   elasticache_subnet_group   = module.vpc.elasticache_subnet_group_name
>   eks_node_security_group_id = module.eks.node_security_group_id
>   db_connection_string       = "postgresql://admin:${var.db_password}@${module.rds.endpoint}:5432/acme"
> }
> ```
>
> **Requirements the author was given:**
> - Tenant data must be fully isolated — one tenant must never be able to access another tenant's resources
> - PHI encryption at rest (KMS-backed SSE on S3, encryption on ElastiCache)
> - Encryption in transit for the session store
> - IRSA for workload identity — no static AWS credentials
> - Session store must be resilient (this is production healthcare)
> - Network traffic in the tenant namespace restricted to expected sources
> - Module must be reusable — we'll call it once per tenant onboarding
>
> **Testing:** Applied successfully for `acme-health` tenant in the dev environment. Namespace created, pods can access S3, Redis is reachable, schema init ran cleanly.

## Target Time: 60 minutes

We respect your time. This should take about an hour. If you find yourself going over, submit what you have with a note about what you'd prioritize next. We're evaluating your judgment and reasoning, not completeness.

## What to Submit

1. A modified `terraform/main.tf` with your fixes applied
2. A `DECISIONS.md` file explaining your changes (see format below)

## Your Tasks

Review `terraform/main.tf` as you would for a real teammate, then fix it:

1. **Identify issues** and categorize each as:
   - **Blocking** — you'd request changes; must be fixed before merge
   - **Suggestion** — worth improving but wouldn't hold up the PR
   - **Question** — ambiguous; you'd ask the author for context before deciding

2. **Fix your blocking issues** directly in `terraform/main.tf`. We want to see working code, not just descriptions of what you'd change. Your fixes should be production-ready — the kind of code you'd approve in a PR.

3. **Check the requirements** — did the author meet them all? Anything missing or only partially addressed? If you add resources to close gaps, include them in your modified `main.tf`.

## DECISIONS.md Format

Use whatever structure works for you. We care about clear reasoning, not formatting. At minimum:
- Issues found with category (blocking / suggestion / question)
- For each blocking issue you fixed: what was wrong, what breaks in production if merged as-is, and why your fix addresses it
- Whether requirements were met
- Any suggestions you chose not to implement and why (time, tradeoffs, needs more context)
- Any questions you'd leave as PR comments for the author

## Notes

- Use whatever tools and resources you normally would.
- Our live technical debrief will focus on your reasoning — be prepared to explain your decisions, discuss alternatives, and walk through failure scenarios.
- If something is ambiguous, make a defensible call and note your assumption. "I'd ask the author" is a valid answer.
- Not everything is wrong — part of a good review is recognizing what's done well.
