# typed: false
# frozen_string_literal: true

# A reservation the game coordinator made for a match, rather than one a person
# made to scrim on.
#
# The coordinator already knows all of this; the reason it is stored here is
# that the server does not, and reservation.cfg is how anything reaches the
# server before it starts. match_id becomes the sv_tags the agent reads back,
# and match_mode chooses which ruleset the config execs.
class AddMatchFieldsToReservations < ActiveRecord::Migration[8.1]
  def change
    add_column :reservations, :match_id, :string
    add_column :reservations, :match_mode, :string
    add_column :reservations, :match_config, :string

    # Matchmaking looks reservations up by match, and only ever for matches
    # that are still running.
    add_index :reservations, :match_id, where: "match_id IS NOT NULL"
  end
end
