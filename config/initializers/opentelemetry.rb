# typed: strict
# frozen_string_literal: true

# Tracing is opt-in: set OTEL_EXPORTER_OTLP_ENDPOINT (or OTEL_TRACES) to a collector.
if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].present? || ENV["OTEL_TRACES"].present?
  # `||=` so the deploy.yml env (host.docker.internal:4318 for Kamal) wins.
  ENV["OTEL_EXPORTER"] ||= "otlp"
  ENV["OTEL_SERVICE_NAME"] ||= SITE_HOST
  ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] ||= "http://localhost:4318"

  OpenTelemetry::SDK.configure do |c|
    c.use_all
  end

  Rails.application.config.after_initialize do
    OtelLogger.setup!
  end
end
