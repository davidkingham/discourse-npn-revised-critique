# frozen_string_literal: true

class RenameRevisedCritiqueCategorySetting < ActiveRecord::Migration[8.0]
  def up
    # Carry over a previously configured category into the new multi-category
    # setting (data_type 11 = category_list). A value of "0" meant "unset" for
    # the old integer setting, so it is dropped rather than migrated.
    execute <<~SQL
      UPDATE site_settings
      SET name = 'revised_critique_category_ids', data_type = 11
      WHERE name = 'revised_critique_category_id'
        AND value <> '0'
        AND NOT EXISTS (
          SELECT 1 FROM site_settings WHERE name = 'revised_critique_category_ids'
        )
    SQL

    execute <<~SQL
      DELETE FROM site_settings WHERE name = 'revised_critique_category_id'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
