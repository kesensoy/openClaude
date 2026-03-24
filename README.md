# openClaude (DEPRECATED)

This project has been removed due to the [litellm supply chain compromise](https://github.com/BerriAI/litellm/issues/24512) discovered on March 24, 2026.

LiteLLM versions 1.82.7 and 1.82.8 on PyPI contained a credential-stealing payload that exfiltrated SSH keys, cloud credentials, environment variables, and other secrets. The attack originated from a compromised Trivy vulnerability scanner in BerriAI's CI/CD pipeline.

This project depended on litellm as a local proxy. The dependency has been fully removed.
