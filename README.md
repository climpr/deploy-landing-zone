# Climpr - Deploy Landing Zone

![Climpr logo](https://www.climpr.com/img/about.jpg)

<!-- TOC -->

- [Climpr - Deploy Landing Zone](#climpr---deploy-landing-zone)
  - [Introduction](#introduction)
    - [Goals](#goals)
    - [Non-Goals](#non-goals)
  - [Getting started](#getting-started)
    - [How to use this action](#how-to-use-this-action)
  - [Structure](#structure)
    - [High level](#high-level)
    - [Landing Zones](#landing-zones)
    - [Archetypes](#archetypes)
    - [Landing Zone definitions](#landing-zone-definitions)

<!-- /TOC -->

## Introduction

The purpose of this solution is to provision and maintain Platform and Application Landing Zones according to the principles in [Azure Enterprise Scale Landing Zones](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/) using Infrastructure as Code (IaC).

### Goals

- Provide self-service provisioning capabilities for new application Landing Zones
- Support the responsibility model of the Enterprise Scale architecture is met. Granting Application Landing Zone owners as much freedom and autonomy in their Landing Zones as possible
- Code should be easy to understand and focus on readability
- All day to day interaction should be with purely declarative code, stating `what` you want to deploy, not `how` to deploy it
- The solution should be flexible enough to easily add support for other programming languages and/or cloud providers

### Non-Goals

- Operating or maintaining the actual workloads, applications or systems contained in the landing zones themselves.

## Getting started

To use this action, you need to follow the steps below:

1. Open the repository directory in which you want to install the `lz-management` solution. Create the repository first if necessary.
2. Navigate to the [bootstrap.ps1](https://insertlinkhere) script, and run it in a PowerShell session in the root directory of the repository.
3. Validate and update the `.github/workflows/deploy-landing-zones.yaml` workflow file to reflect your desired configuration.
4. Validate and update the `lz-management/climprconfig.json` configuration file to reflect your desired configuration.
5. Create the archetypes you need and place them in the `lz-management/archetypes` directory.
6. Create a GitHub app (TODO: Insert instructions)
7. Create a User Assigned Managed Identity for the solution. (You can use the [Climpr Bicep Deployment module](https://github.com/climpr/deploy-bicep/) for this.)
8. In GitHub, create the environment and upload the variables and secrets referenced in the `.github/workflows/deploy-landing-zones.yaml` file.
9. You are good to go...

### How to use this action

This action can be used multiple ways.

- Single Landing Zone deployment.
- Part of a dynamic, multi-deployment strategy using the `matrix` capabilities in Github.

It requires the repository to be checked out before use, and that the Github runner is logged in to the respective Azure environment.

It is called as a step like this:

```yaml
# ...
steps:
  - name: Checkout repository
    uses: actions/checkout@v4

  - name: Get GH Token
    id: gh-app-token
    uses: actions/create-github-app-token@v1
    with:
      app-id: ${{ vars.GH_APP_ID }}
      private-key: ${{ secrets.GH_APP_PRIVATE_KEY }}
      owner: ${{ github.repository_owner }}

  - name: Azure login via OIDC
    uses: azure/login@v2
    with:
      client-id: ${{ vars.APP_ID }}
      tenant-id: ${{ vars.TENANT_ID }}
      subscription-id: ${{ vars.SUBSCRIPTION_ID }}

  - name: Set up Landing Zone
    uses: climpr/deploy-landing-zone@v1
    with:
      solution-path: <Path to the Climpr Landing Zones solution directory.>
      landing-zone-path: <Landing Zone directory path.>
      archetypes-path: <Archetypes path.>
      root-landing-zones-path: <Root path for all Landing Zones.>
      decommissioned-landing-zones-path: <Root path for all decommissioned Landing Zones.>
      az-ps-version: <The version of Az PS modules to install.>
      bicep-version: <The version of Bicep to install.>
      github-token: <The token for the GitHub app that is allowed to create and update repositories in the organization.>
# ...
```

## Structure

The repository is structured as follows:

### High level

| Path            | Description                                                   |
| --------------- | ------------------------------------------------------------- |
| `.github`       | Workflows                                                     |
| `lz-management` | The directory containing the Landing Zone Management solution |

### Landing Zones

In Climpr a Landing Zone is defined as a GitHub repository connected to one or more Azure subscriptions. One for each specified environment. Each specific Azure subscription is called a Landing Zone Environment instance.

Each Landing Zone Environment instance consists of:

- An Azure Subscription: The unit in Azure representing the Landing Zone
- An Archetype: The type of Landing Zone. Examples: Corp and Online (see: [Enterprise Scale - FAQ](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/enterprise-scale/faq#what-about-our-management-group-hierarchy))
- A Blueprint: The IaC template for the Archetype.

The Blueprint of the Archetype is applied to the Subscription to create a Landing Zone Environment instance.

To support these principles, the solution directory is structured as follows:

| Path                                         | Description                                      |
| -------------------------------------------- | ------------------------------------------------ |
| `lz-management/archetypes`                   | The templates for each archetype implemented.    |
| `lz-management/landing-zones`                | Landing Zone definitions                         |
| `lz-management/landing-zones-decommissioned` | Where to place disabled Landing Zone definitions |

### Archetypes

By default, `corp`, `online` and `sandbox` Landing Zones are implemented according to the Enterprise Scale design.
To simplify the development, they all use common Bicep modules located in the `.bicep` directory.

### Landing Zone definitions

The structure supports grouping landing zones in a directory structure to provide necessary type separation and organization for landing zones. How to structure this is all up to you, but by default, Climpr implements:

- `platform`: Platform Landing Zones according to the [Azure Enterprise Scale Landing Zones](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/)
- `application`: Application Landing Zones according to the [Azure Enterprise Scale Landing Zones](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/)
- `sandbox`: Sandboxes

Each Landing Zone has a dedicated directory under the desired root directory `lz-management/landing-zones/<..>/<landingzone>` directory.

A Landing Zone is defined by a file called: `metadata.json`. This file contains the definition of the Landing Zone, both GitHub properties and Azure properties.

For any Landing Zone with an Azure environment, a `.bicepparam` file must be made for each environment. The file must be named: `<environment>.bicepparam`. For example: `prod.bicepparam`. The `.bicepparam` must be linked to the archetype `main.bicep` file with the `using` statement.
