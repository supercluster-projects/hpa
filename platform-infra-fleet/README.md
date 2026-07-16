# platform-infra-fleet
## Central Platform Infrastructure & GitOps Fleet Management Repository

This directory acts as the central GitOps fleet repository (`platform-infra-fleet`) for managing cluster bootstrapping, environment-wide configurations, and service delivery across staging and production spokeworks.

### Directory Structure
*   `stages/`: Environment overlays for distinct deployment environments.
    *   `stages/dev/`: Local development high-parity deployment overlays.
    *   `stages/staging/`: Staging cluster environment profiles.
    *   `stages/production/`: Production cluster fleet environments.
*   `applicationsets/`: High-scale declarative Argo CD ApplicationSet definitions.
*   `templates/`: Golden Path template repository blueprints for the Backstage IDP Scaffolder.
