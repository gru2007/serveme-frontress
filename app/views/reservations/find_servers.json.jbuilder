# frozen_string_literal: true

server_entries = @servers.map do |server|
  {
    id: server.id,
    name: server.name,
    flag: server.location&.flag,
    ip: server.public_ip,
    port: server.public_port,
    ip_and_port: "#{server.public_ip}:#{server.public_port}",
    resolved_ip: server.public_resolved_ip,
    sdr: server.sdr,
    latitude: server.latitude,
    longitude: server.longitude
  }
end

docker_host_entries = (@docker_hosts || []).map do |dh|
  {
    id: "dh-#{dh.id}",
    name: "#{dh.city} (#{dh.hostname})",
    flag: dh.location&.flag,
    ip: dh.hostname,
    port: dh.start_port,
    ip_and_port: "#{dh.hostname}:#{dh.start_port}",
    resolved_ip: dh.ip
  }
end

# A container on this machine, when one can still be started. Offered first,
# and identified by the same virtual id the JSON API uses.
local_docker_entries = @local_docker ? [ CloudProvider::Docker.virtual_server_entry ] : []

json.servers(local_docker_entries + docker_host_entries + server_entries)
