# frozen_string_literal: true

class CreateDocumentsAndChunks < ActiveRecord::Migration[7.1]
  def change
    enable_extension "vector" unless extension_enabled?("vector")

    create_table :documents do |t|
      t.string :title, null: false
      t.text :content, null: false
      t.string :status, null: false, default: "processing"
      t.timestamps
    end

    create_table :chunks do |t|
      t.references :document, null: false, foreign_key: true
      t.text :content, null: false
      # Dimension must match your embeddings model's output size.
      t.column :embedding, "vector(768)"
      t.timestamps
    end

    # Approximate-nearest-neighbour index for fast cosine search.
    add_index :chunks, :embedding, using: :ivfflat, opclass: :vector_cosine_ops
  end
end
