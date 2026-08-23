# typed: true
# frozen_string_literal: true

# One site, one Stripe account. Environment first, so a deployment without
# Rails credentials can still take payments.
Stripe.api_key = ENV["STRIPE_API_KEY"].presence || Rails.application.credentials.dig(:stripe, :api_key)
STRIPE_PUBLISHABLE_KEY = ENV["STRIPE_PUBLISHABLE_KEY"].presence ||
  Rails.application.credentials.dig(:stripe, :publishable_key)

# Update to latest API version that supports automatic_payment_methods
Stripe.api_version = "2023-10-16"
