# typed: strict

# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rake db:seed (or created alongside the db with db:setup).
#
# Examples:
#
#   cities = City.create([{ name: 'Chicago' }, { name: 'Copenhagen' }])
#   Mayor.create(name: 'Emanuel', city: cities.first)
#
# No servers are seeded.
#
# Game servers in this fork are containers started per reservation, so there is
# nothing to list here: with FRONTRESS_LOCAL_DOCKER=1 this machine can host
# them, and remote docker hosts are added under /admin/docker_hosts. A server
# you run yourself can still be added by hand -- see docs/DOCKER.md.

unless ServerConfig.all.any?
  # The rulesets a reservation can ask for. They are file names on the game
  # server (game/tc2/cfg in the game repository, baked into the container
  # image), and the coordinator names the same two for its match groups.
  configs = %w[frontress_casual frontress_ranked frontress_match]
  configs.each do |config|
    ServerConfig.create(file: config)
  end
  puts "Seeded configs #{configs.join(', ')}" unless Rails.env.test?
end

unless Whitelist.all.any?
  # The only weapon whitelist that ships with the game. Ranked execs it itself;
  # this row is for a reservation that wants to run it without being a match.
  whitelists = [ 'whitelist_competitive.txt' ]
  whitelists.each do |whitelist|
    Whitelist.create(file: whitelist)
  end
  puts "Seeded whitelists #{whitelists.join(', ')}" unless Rails.env.test?
end

unless Location.all.any?
  locations = [
    { name: 'Austria',        flag: 'at' },
    { name: 'Belgium',        flag: 'be' },
    { name: 'Canada',         flag: 'ca' },
    { name: 'Czech Republic', flag: 'cz' },
    { name: 'Denmark',        flag: 'dk' },
    { name: 'England',        flag: 'en' },
    { name: 'EU',             flag: 'europeanunion' },
    { name: 'Germany',        flag: 'de' },
    { name: 'Finland',        flag: 'fi' },
    { name: 'France',         flag: 'fr' },
    { name: 'Hungary',        flag: 'hu' },
    { name: 'Ireland',        flag: 'ie' },
    { name: 'Israel',         flag: 'il' },
    { name: 'Latvia',         flag: 'lt' },
    { name: 'Netherlands',    flag: 'nl' },
    { name: 'Norway',         flag: 'no' },
    { name: 'Russia',         flag: 'ru' },
    { name: 'Scotland',       flag: 'scotland' },
    { name: 'Spain',          flag: 'es' },
    { name: 'UK',             flag: 'uk' },
    { name: 'USA',            flag: 'us' }
  ]
  locations.each do |location|
    Location.where(name: location[:name], flag: location[:flag]).first_or_create
  end

  Group.create!(name: 'Donators') unless Group.all.any?
end
