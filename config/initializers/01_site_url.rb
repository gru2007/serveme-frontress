# typed: true
# frozen_string_literal: true

# The one address this site answers on.
#
# Almost everything user-facing derives from these two: page copy, the API key
# label, the Discord command hint, the address game servers send their logs to.
# SITE_HOST is derived from SITE_URL when it is not set on its own, because
# setting one and forgetting the other is how a site ends up calling itself
# "localhost" on every page.
require "uri"

site_url = ENV["SITE_URL"].presence
site_host = ENV["SITE_HOST"].presence ||
  (site_url && URI.parse(site_url).host) ||
  "localhost"

SITE_HOST = site_host.freeze
SITE_URL = (site_url || "http://#{SITE_HOST}:3000").freeze
