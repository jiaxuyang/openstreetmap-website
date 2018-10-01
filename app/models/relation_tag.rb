# == Schema Information
#
# Table name: current_relation_tags
#
#  relation_id :integer          not null, primary key
#  k           :string           default(""), not null, primary key
#  v           :string           default(""), not null
#
# Foreign Keys
#
#  current_relation_tags_id_fkey  (relation_id => current_relations.id)
#

class RelationTag < ActiveRecord::Base
  self.table_name = "current_relation_tags"
  self.primary_keys = "relation_id", "k"

  belongs_to :relation

  attr_accessor :skip_uniqueness
  validates :relation, :presence => true, :associated => true, :unless => :skip_uniqueness
  validates :k, :v, :allow_blank => true, :length => { :maximum => 255 }
  validates :k, :uniqueness => { :scope => :relation_id }, :unless => :skip_uniqueness
end
