# EMQX

[![GitHub Release](https://img.shields.io/github/release/emqx/emqx?color=brightgreen&label=Release)](https://github.com/emqx/emqx/releases)
[![Build Status](https://github.com/emqx/emqx/actions/workflows/_push-entrypoint.yaml/badge.svg)](https://github.com/emqx/emqx/actions/workflows/_push-entrypoint.yaml)
[![Slack](https://img.shields.io/badge/Slack-EMQ-39AE85?logo=slack)](https://slack-invite.emqx.io/)
[![Discord](https://img.shields.io/discord/931086341838622751?label=Discord&logo=discord)](https://discord.gg/xYGf3fQnES)
[![X](https://img.shields.io/badge/Follow-EMQ-1DA1F2?logo=x)](https://x.com/EMQTech)
[![YouTube](https://img.shields.io/badge/Subscribe-EMQ-FF0000?logo=youtube)](https://www.youtube.com/channel/UC5FjR77ErAxvZENEWzQaO5Q)


EMQX is the world's most scalable and reliable MQTT platform, designed for high-performance, reliable, and secure IoT data infrastructure. It supports MQTT 5.0, 3.1.1, and 3.1, as well as other protocols like MQTT-SN, CoAP, LwM2M, and MQTT over QUIC. EMQX enables you to connect millions of IoT devices, process and route messages in real time, and integrate with a wide range of backend data systems. It's ideal for applications in AI, IoT, Industrial IoT (IIoT), connected vehicles, smart cities, and beyond.

**Starting from v5.9.0, EMQX has unified all features from the previous Open Source and Enterprise editions into a single, powerful offering with the Business Source License (BSL) 1.1.**

If you want to understand why we made the change, please read this [blog post](https://www.emqx.com/en/news/emqx-adopts-business-source-license).

Please go to the [License](#License) section for more details about BSL 1.1.

## Key Features

EMQX delivers a powerful set of capabilities for modern connected systems:

### Comprehensive Protocol Support

- Full MQTT v5.0, v3.1.1, and v3.1 support.
- [MQTT over QUIC](https://docs.emqx.com/en/emqx/latest/mqtt-over-quic/introduction.html): Leverage the benefits of QUIC for faster connection establishment, reduced head-of-line blocking, and seamless connection migration.
- Support for other IoT protocols like [LwM2M](https://docs.emqx.com/en/emqx/latest/gateway/lwm2m.html), [CoAP](https://docs.emqx.com/en/emqx/latest/gateway/coap.html), [MQTT-SN](https://docs.emqx.com/en/emqx/latest/gateway/mqttsn.html), and more through [gateways](https://docs.emqx.com/en/emqx/latest/gateway/gateway.html).

### Massive Scalability & High Availability

- [Connect](https://www.emqx.com/en/solutions/iot-device-connectivity) 100M+ of concurrent MQTT clients with a single cluster.
- [Process](https://www.emqx.com/en/solutions/reliable-mqtt-messaging) millions of messages per second with sub-millisecond latency.
- [Masterless clustering](https://docs.emqx.com/en/emqx/latest/deploy/cluster/introduction.html) for high availability and fault tolerance.
- Seamless global communication with [EMQX Cluster Linking](https://www.emqx.com/en/solutions/cluster-linking).

### Powerful Rule Engine & Data Integration

- SQL-based [Rule Engine](https://www.emqx.com/en/solutions/mqtt-data-processing) to process, transform, enrich, and filter in-flight data.
- Seamless data bridging and [integration](https://www.emqx.com/en/solutions/mqtt-data-integration) with 50+ cloud services and enterprise systems, including:
  - **Message Queues**: [Kafka](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-kafka.html), [RabbitMQ](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-rabbitmq.html), [Pulsar](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-pulsar.html), [RocketMQ](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-rocketmq.html), etc.
  - **Databases**: [PostgreSQL](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-pgsql.html), [MySQL](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-mysql.html), [MongoDB](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-mongodb.html), [Redis](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-redis.html), [ClickHouse](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-clickhouse.html), [InfluxDB](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-influxdb.html), etc.
  - **Cloud Services**: [AWS Kinesis](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-kinesis.html), [GCP Pub/Sub](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-gcp-pubsub.html), [Azure Event](https://docs.emqx.com/en/emqx/latest/data-integration/data-bridge-azure-event-hub.html), [Confluent Cloud](https://docs.emqx.com/en/emqx/latest/data-integration/confluent-sink.html),  and more.
- [Webhook](https://docs.emqx.com/en/emqx/latest/data-integration/webhook.html) support for easy integration with custom services.

### [Flow Designer](https://docs.emqx.com/en/emqx/latest/flow-designer/introduction.html)

- Drag‑and‑drop canvas to orchestrate real‑time data pipelines with zero code, using nodes for rules, integrations, and AI tasks.

### [Smart Data Hub](https://docs.emqx.com/en/cloud/latest/data_hub/smart_data_hub.html)

- [Schema Registry](https://docs.emqx.com/en/cloud/latest/data_hub/schema_registry.html): Define, store, and manage data schemas to ensure consistency.
- [Schema Validation](https://docs.emqx.com/en/cloud/latest/data_hub/schema_validation.html): Validate incoming data against registered schemas to maintain data integrity.
- [Message Transformation](https://docs.emqx.com/en/cloud/latest/data_hub/message_transformation.html): Convert data between different formats and structures to facilitate seamless integration.

### [AI Processing & Integration](https://www.emqx.com/en/solutions/artificial-intelligence):

- Native AI processing capabilities for IoT data streams.
- Integration with popular AI services.
- Support for AI-driven decision making at the edge or in the cloud.

### Robust [Security](https://www.emqx.com/en/solutions/mqtt-security)

- [Secure connections](https://docs.emqx.com/en/emqx/latest/network/overview.html) with TLS/SSL and WSS.
- Flexible [authentication](https://docs.emqx.com/en/emqx/latest/access-control/authn/authn.html) mechanisms: username/password, JWT, PSK, X.509 certificates, etc.
- Granular access control with [ACLs](https://docs.emqx.com/en/emqx/latest/access-control/authz/authz.html).
- Integration with external authentication databases ([LDAP](https://docs.emqx.com/en/emqx/latest/access-control/authn/ldap.html), [SQL](https://docs.emqx.com/en/emqx/latest/access-control/authn/postgresql.html), [Redis](https://docs.emqx.com/en/emqx/latest/access-control/authn/redis.html)).

### Advanced Observability & Management:

- Comprehensive monitoring with [Prometheus](https://docs.emqx.com/en/emqx/latest/observability/prometheus.html), [Grafana](https://grafana.com/grafana/dashboards/17446-emqx/), [Datadog](https://docs.emqx.com/en/emqx/latest/observability/datadog.html), and [OpenTelemetry](https://docs.emqx.com/en/emqx/latest/observability/opentelemetry/opentelemetry.html).
- Detailed logging and [tracing](https://docs.emqx.com/en/emqx/latest/observability/tracer.html) capabilities.
- User-friendly [Dashboard](https://docs.emqx.com/en/emqx/latest/dashboard/introduction.html) for cluster overview and management.
- Rich [HTTP API](https://docs.emqx.com/en/emqx/latest/admin/api.html) for automation and third-party integration.

### Extensibility

- [Plugin](https://docs.emqx.com/en/emqx/latest/extensions/plugins.html) architecture for extending functionality.
- [Hooks](https://docs.emqx.com/en/emqx/latest/extensions/hooks.html) for customizing behavior at various points in the message lifecycle.

### Unified Experience:

- With the BSL 1.1 license (from v5.9.0), all features, including those previously exclusive to the enterprise edition, are available to all developers.

## Quick Start

### Try EMQX Cloud

The simplest way to set up EMQX is to create a managed deployment with EMQX Cloud. You can [try EMQX Cloud for free](https://www.emqx.com/en/signup?utm_source=github.com&utm_medium=referral&utm_campaign=emqx-readme-to-cloud&continue=https://cloud-intl.emqx.com/console/deployments/0?oper=new).

- [EMQX Serverless](https://www.emqx.com/en/cloud/serverless-mqtt)
- [EMQX Dedicated](https://www.emqx.com/en/cloud/dedicated)
- [EMQX BYOC](https://www.emqx.com/en/cloud/byoc)

### Run a single node using Docker

```
docker run -d --name emqx \
  -p 1883:1883 -p 8083:8083 -p 8084:8084 \
  -p 8883:8883 -p 18083:18083 \
  emqx/emqx-enterprise:latest
```

Next, please follow the [Install EMQX Using Docker](https://docs.emqx.com/en/emqx/latest/deploy/install-docker.html) guide for further instructions.

### Run EMQX cluster on Kubernetes

Please refer to the official [EMQX Operator](https://docs.emqx.com/en/emqx-operator/latest/getting-started/getting-started.html) documentation for details.

### Download EMQX

If you prefer to install and manage EMQX yourself, you can download the latest version from [the official site](https://www.emqx.com/en/downloads-and-install/enterprise).

For more installation options, see the [EMQX installation documentation](https://docs.emqx.com/en/emqx/latest/deploy/install.html)

## Documentation

- EMQX self-hosted: [docs.emqx.com/en/emqx/latest](https://docs.emqx.com/en/emqx/latest/).
- EMQX Cloud: [docs.emqx.com/en/cloud/latest](https://docs.emqx.com/en/cloud/latest/).

## Contributing

Please see our [contributing guide](./CONTRIBUTING.md).

For more organised improvement proposals, you can send pull requests to [EIP](https://github.com/emqx/eip).

## Community

- Follow us on: [X](https://x.com/EMQTech), [YouTube](https://www.youtube.com/channel/UC5FjR77ErAxvZENEWzQaO5Q).
- Ask Questions: [GitHub Discussions](https://github.com/emqx/emqx/discussions) or [EMQX Community Slack]((https://slack-invite.emqx.io/)).
- Report Bugs: [GitHub Issues](https://github.com/emqx/emqx/issues).
- Discord: [EMQX Discord Server](https://discord.gg/x55DZXE).

## Resources

- EMQX Website: [emqx.com](https://www.emqx.com/)
- EMQX Blog: [emqx.com/en/blog](https://www.emqx.com/en/blog)
- MQTT Client Programming: [Tutorials](https://www.emqx.com/en/blog/category/mqtt-programming)
- MQTT SDKs: [Popular SDKs](https://www.emqx.com/en/mqtt-client-sdk)
- MQTT Tool: [MQTTX](https://mqttx.app/)

## Build From Source

The master branch tracks the latest version 5.

- EMQX 5.4 and newer can be built with OTP 25 or 26
- EMQX 5.9+ can be built with OTP 27

```bash
git clone https://github.com/emqx/emqx.git
cd emqx
make
_build/emqx-enterprise/rel/emqx/bin/emqx console
```

For 4.2 or earlier versions, release has to be built from another repo.

```bash
git clone https://github.com/emqx/emqx-rel.git
cd emqx-rel
make
_build/emqx/rel/emqx/bin/emqx console
```

## Rolling Upgrade Paths Since 5.0

Below is the matrix supported rolling upgrade paths since 5.0.

- Version numbers end with `?` e.g. `6.0?` are future releases.
- ✅: Supported, or planed to support.
- ⚠️:  May experience issues, require manual resolution.
- ❌: Not supported.
- 🔄: Tentative support for future versions.

See release notes for detailed information.

| From\To  | 5.1  | 5.2  | 5.3  | 5.4  | 5.5  | 5.6  | 5.7  | 5.8  | 5.9   | 5.10? | 6.0?  |
|----------|------|------|------|------|------|------|------|------|-------|-------|-------|
| 5.0      | ✅   | ✅   | ✅   | ✅   | ✅   | ✅   | ✅   | ✅   | ⚠️[1]  | ❌[2] | ❌[2] |
| 5.1      | ✅   | ✅   | ✅   | ✅   | ✅   | ✅   | ✅   | ✅   | ✅    | ❌[2] | ❌[2] |
| 5.2      |      | ✅   | ✅   | ✅   | ✅   | ✅   | ✅   | ✅   | ✅    | ❌[2] | ❌[2] |
| 5.3      |      |      | ✅   | ✅   | ✅   | ✅   | ✅   | ✅   | ✅    | ❌[2] | ❌[2] |
| 5.4      |      |      |      | ✅   | ✅   | ⚠️    | ✅   | ✅   | ✅    | ✅    | 🔄    |
| 5.5      |      |      |      |      | ✅   | ⚠️    | ✅   | ✅   | ✅    | ✅    | 🔄    |
| 5.6      |      |      |      |      |      | ✅   | ✅   | ✅   | ✅    | ✅    | 🔄    |
| 5.7      |      |      |      |      |      |      | ✅   | ✅   | ✅    | ✅    | 🔄    |
| 5.8      |      |      |      |      |      |      |      | ✅   | ✅    | ✅    | 🔄    |
| 5.9      |      |      |      |      |      |      |      |      | ✅    | ✅    | ✅    |
| 5.10?    |      |      |      |      |      |      |      |      |       | ✅    | ✅    |
| 6.0?     |      |      |      |      |      |      |      |      |       |       | ✅    |

- [1] Old limiter configs should be deleted from the config files (`etc/emqx.conf` and `data/configs/cluster-override.conf`) before upgrade.
- [2] Pre-5.4 routing table will be deleted. Upgrade to 5.9 first, then perform a full-cluster restart (not rolling) before upgrade to 5.10 or later.

## License

### Important License Update

Effective from version **5.9.0**, EMQX has transitioned from Apache 2.0 to the Business Source License (BSL) 1.1.

### License Requirement for Clustering (v5.9.0+)

Starting with EMQX v5.9.0, due to the license change and the unification of all features, deploying an EMQX cluster (more than 1 node) requires a license file to be loaded.

Please refer to the following resources for details on license acquisition, application, and the specifics of the BSL 1.1.

- **News**: [EMQX Adopts Business Source License](https://www.emqx.com/en/news/emqx-adopts-business-source-license)
- **Blog**: [Adopting Business Source License to Accelerate MQTT and AI Innovation](https://www.emqx.com/en/blog/adopting-business-source-license-to-accelerate-mqtt-and-ai-innovation)
- **FAQ**: [EMQX License FAQ](https://www.emqx.com/en/content/license-faq)
