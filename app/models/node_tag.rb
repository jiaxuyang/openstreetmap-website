# == Schema Information
#
# Table name: current_node_tags
#
#  node_id :integer          not null, primary key
#  k       :string           default(""), not null, primary key
#  v       :string           default(""), not null
#
# Foreign Keys
#
#  current_node_tags_id_fkey  (node_id => current_nodes.id)
#

class NodeTag < ActiveRecord::Base
  self.table_name = "current_node_tags"
  self.primary_keys = "node_id", "k"

  belongs_to :node

  attr_accessor :skip_uniqueness
  validates :node, :presence => true, :associated => true, :unless => :skip_uniqueness
  validates :k, :v, :allow_blank => true, :length => { :maximum => 255 }
  validates :k, :uniqueness => { :scope => :node_id }, :unless => :skip_uniqueness
end
