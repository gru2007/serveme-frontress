# typed: false
# frozen_string_literal: true

class MakeActiveMatchReservationsUnique < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :reservations,
              [ :user_id, :match_id ],
              unique: true,
              where: "match_id IS NOT NULL AND ended = false",
              name: "index_reservations_on_user_and_open_match",
              algorithm: :concurrently
  end
end
