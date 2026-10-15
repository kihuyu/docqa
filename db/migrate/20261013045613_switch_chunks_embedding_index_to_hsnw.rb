class SwitchChunksEmbeddingIndexToHsnw < ActiveRecord::Migration[8.1]
  INDEX = "index_chunks_on_embedding"

  def up
    return if index_method == "hnsw"

    remove_index :chunks, name: INDEX, if_exists: true
    add_index :chunks, :embedding, using: :hnsw, opclass: :vector_cosine_ops, name: INDEX
  end

  def down
    return if index_method == "ivfflat"

    remove_index :chunks, name: INDEX, if_exists: true
    add_index :chunks, :embedding, using: :ivfflat, opclass: :vector_cosine_ops, name: INDEX
  end

  private

  # Reads the access method (hnsw / ivfflat) of the existing index, or nil.
  def index_method
    select_value(<<~SQL)
      SELECT am.amname
      FROM pg_class idx
      JOIN pg_am am ON am.oid = idx.relam
      WHERE idx.relname = #{connection.quote(INDEX)}
    SQL
  end
end
