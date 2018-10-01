# == Schema Information
#
# Table name: current_nodes
#
#  id           :bigint(8)        not null, primary key
#  latitude     :integer          not null
#  longitude    :integer          not null
#  changeset_id :bigint(8)        not null
#  visible      :boolean          not null
#  timestamp    :datetime         not null
#  tile         :bigint(8)        not null
#  version      :bigint(8)        not null
#
# Indexes
#
#  current_nodes_tile_idx       (tile)
#  current_nodes_timestamp_idx  (timestamp)
#
# Foreign Keys
#
#  current_nodes_changeset_id_fkey  (changeset_id => changesets.id)
#

class Node < ActiveRecord::Base
  require "xml/libxml"

  include GeoRecord
  include ConsistencyValidations
  include NotRedactable
  include ObjectMetadata

  self.table_name = "current_nodes"

  belongs_to :changeset

  has_many :old_nodes, -> { order(:version) }

  has_many :way_nodes
  has_many :ways, :through => :way_nodes

  has_many :node_tags

  has_many :old_way_nodes
  has_many :ways_via_history, :class_name => "Way", :through => :old_way_nodes, :source => :way

  has_many :containing_relation_members, :class_name => "RelationMember", :as => :member
  has_many :containing_relations, :class_name => "Relation", :through => :containing_relation_members, :source => :relation

  attr_accessor :skip_uniqueness
  validates :id, :uniqueness => true, :presence => { :on => :update },
                 :numericality => { :on => :update, :integer_only => true }, :unless => :skip_uniqueness
  validates :version, :presence => true,
                      :numericality => { :integer_only => true }
  validates :changeset_id, :presence => true,
                           :numericality => { :integer_only => true }
  validates :latitude, :presence => true,
                       :numericality => { :integer_only => true }
  validates :longitude, :presence => true,
                        :numericality => { :integer_only => true }
  validates :timestamp, :presence => true
  validates :changeset, :associated => true, :unless => :skip_uniqueness
  validates :visible, :inclusion => [true, false]

  validate :validate_position

  scope :visible, -> { where(:visible => true) }
  scope :invisible, -> { where(:visible => false) }

  # Sanity check the latitude and longitude and add an error if it's broken
  def validate_position
    errors.add(:base, "Node is not in the world") unless in_world?
  end

  # Read in xml as text and return it's Node object representation
  def self.from_xml(xml, create = false)
    p = XML::Parser.string(xml, :options => XML::Parser::Options::NOERROR)
    doc = p.parse

    doc.find("//osm/node").each do |pt|
      return Node.from_xml_node(pt, create)
    end
    raise OSM::APIBadXMLError.new("node", xml, "XML doesn't contain an osm/node element.")
  rescue LibXML::XML::Error, ArgumentError => ex
    raise OSM::APIBadXMLError.new("node", xml, ex.message)
  end

  def self.from_xml_node(pt, create = false)
    node = Node.new

    raise OSM::APIBadXMLError.new("node", pt, "lat missing") if pt["lat"].nil?
    raise OSM::APIBadXMLError.new("node", pt, "lon missing") if pt["lon"].nil?

    node.lat = OSM.parse_float(pt["lat"], OSM::APIBadXMLError, "node", pt, "lat not a number")
    node.lon = OSM.parse_float(pt["lon"], OSM::APIBadXMLError, "node", pt, "lon not a number")
    raise OSM::APIBadXMLError.new("node", pt, "Changeset id is missing") if pt["changeset"].nil?

    node.changeset_id = pt["changeset"].to_i

    raise OSM::APIBadUserInput, "The node is outside this world" unless node.in_world?

    # version must be present unless creating
    raise OSM::APIBadXMLError.new("node", pt, "Version is required when updating") unless create || !pt["version"].nil?

    node.version = create ? 0 : pt["version"].to_i

    unless create
      raise OSM::APIBadXMLError.new("node", pt, "ID is required when updating.") if pt["id"].nil?

      node.id = pt["id"].to_i
      # .to_i will return 0 if there is no number that can be parsed.
      # We want to make sure that there is no id with zero anyway
      raise OSM::APIBadUserInput, "ID of node cannot be zero when updating." if node.id.zero?
    end

    # We don't care about the time, as it is explicitly set on create/update/delete
    # We don't care about the visibility as it is implicit based on the action
    # and set manually before the actual delete
    node.visible = true

    # Start with no tags
    node.tags = {}

    # Add in any tags from the XML
    pt.find("tag").each do |tag|
      raise OSM::APIBadXMLError.new("node", pt, "tag is missing key") if tag["k"].nil?
      raise OSM::APIBadXMLError.new("node", pt, "tag is missing value") if tag["v"].nil?

      node.add_tag_key_val(tag["k"], tag["v"])
    end

    node
  end

  ##
  # the bounding box around a node, which is used for determining the changeset's
  # bounding box
  def bbox
    BoundingBox.new(longitude, latitude, longitude, latitude)
  end

  def self.update_changeset_bbox_bulk(changeset, node_ids)
    rows = Node.select("min(longitude) as min_lon, min(latitude) as min_lat, max(longitude) as max_lon, max(latitude) as max_lat")
               .where(:id => node_ids.uniq)
    temp_bbox = BoundingBox.new rows[0]["min_lon"], rows[0]["min_lat"], rows[0]["max_lon"], rows[0]["max_lat"]
    changeset.update_bbox!(temp_bbox)
  end

  # Should probably be renamed delete_from to come in line with update
  def delete_with_history!(new_node, user)
    raise OSM::APIAlreadyDeletedError.new("node", new_node.id) unless visible

    # need to start the transaction here, so that the database can
    # provide repeatable reads for the used-by checks. this means it
    # shouldn't be possible to get race conditions.
    Node.transaction do
      lock!
      check_consistency(self, new_node, user)
      ways = Way.joins(:way_nodes).where(:visible => true, :current_way_nodes => { :node_id => id }).order(:id)
      raise OSM::APIPreconditionFailedError, "Node #{id} is still used by ways #{ways.collect(&:id).join(',')}." unless ways.empty?

      rels = Relation.joins(:relation_members).where(:visible => true, :current_relation_members => { :member_type => "Node", :member_id => id }).order(:id)
      raise OSM::APIPreconditionFailedError, "Node #{id} is still used by relations #{rels.collect(&:id).join(',')}." unless rels.empty?

      self.changeset_id = new_node.changeset_id
      self.tags = {}
      self.visible = false

      # update the changeset with the deleted position
      changeset.update_bbox!(bbox)

      save_with_history!
    end
  end

  def self.delete_with_history_bulk!(nodes, changeset, if_unused = false)
    node_hash = nodes.collect { |node| [node.id, node] }.to_h
    skipped = {}
    Node.transaction do
      # check if node ids exists
      node_ids = node_hash.keys
      old_nodes = Node.select("id, version, visible").where(:id => node_ids).lock
      raise OSM::APIBadUserInput, "Node not exist. id: " + (node_ids - old_nodes.collect(&:id)).join(", ") unless node_ids.length == old_nodes.length
      old_nodes.each do |old|
        unless old.visible
          # already deleted
          raise OSM::APIAlreadyDeletedError.new("node", old.id) unless if_unused
          # if-unused: ignore and do next.
          # return old db version to client.
          node_hash[old.id].version = old.version
          skipped[old.id] = node_hash[old.id]
          node_hash.delete old.id
          next
        end
        # check if client version equals db version
        new = node_hash[old.id]
        new.changeset = changeset
        old.check_consistency(old, new, changeset.user)
      end
      # discover nodes referred by ways or relations
      way_nodes = WayNode.select("node_id, way_id").where(:node_id => node_hash.keys).group_by(&:node_id)
      raise OSM::APIPreconditionFailedError, "Node #{way_nodes.first[0]} is still used by ways #{way_nodes.first[1].collect(&:way_id).join(',')}." unless way_nodes.empty? || if_unused
      way_nodes.each_key do |node_id|
        skipped[node_id] = node_hash[node_id]
        node_hash.delete node_id
      end
      rel_members = RelationMember.select("member_id, relation_id").where(:member_type => "Node", :member_id => node_hash.keys).group_by(&:member_id)
      raise OSM::APIPreconditionFailedError, "Node #{rel_members.first[0]} is still used by relations #{rel_members.first[1].collect(&:relation_id).join(',')}." unless rel_members.empty? || if_unused
      rel_members.each_key do |node_id|
        skipped[node_id] = node_hash[node_id]
        node_hash.delete node_id
      end
      # modify columns to delete
      to_delete_nodes = node_hash.values
      to_delete_nodes.each do |node|
        # set lat lon not null, won't really modify latitude, longitude, tile.
        # just a work-around to skip not-null constraint.
        node.latitude = 0 if node.latitude.nil?
        node.longitude = 0 if node.longitude.nil?
        node.tags = {}
        node.visible = false
      end
      # update changeset bbox
      update_changeset_bbox_bulk(changeset, to_delete_nodes.collect(&:id))
      # save
      save_with_history_bulk!(to_delete_nodes, changeset, true)
    end
    skipped
  end

  def update_from(new_node, user)
    Node.transaction do
      lock!
      check_consistency(self, new_node, user)

      # update changeset first
      self.changeset_id = new_node.changeset_id
      self.changeset = new_node.changeset

      # update changeset bbox with *old* position first
      changeset.update_bbox!(bbox)

      # FIXME: logic needs to be double checked
      self.latitude = new_node.latitude
      self.longitude = new_node.longitude
      self.tags = new_node.tags
      self.visible = true

      # update changeset bbox with *new* position
      changeset.update_bbox!(bbox)

      save_with_history!
    end
  end

  def self.update_from_bulk(nodes, changeset)
    Node.transaction do
      nodes.sort_by!(&:id)
      node_ids = nodes.collect(&:id)
      # get id, version to check
      # get lat, lon to update changeset
      # lock for update
      old_nodes = Node.select("id, latitude, longitude, version").where(:id => node_ids).order(:id).lock
      node_ids.length.times do |i|
        nodes[i].changeset = changeset
        old_nodes[i].check_consistency(old_nodes[i], nodes[i], changeset.user)
        # update changeset bbox with *old* position first
        changeset.update_bbox!(old_nodes[i].bbox)
        nodes[i].visible = true

        # update changeset bbox with *new* position
        changeset.update_bbox!(nodes[i].bbox)
      end
      save_with_history_bulk!(nodes, changeset)
    end
  end

  def create_with_history(user)
    check_create_consistency(self, user)
    self.version = 0
    self.visible = true

    # update the changeset to include the new location
    changeset.update_bbox!(bbox)

    save_with_history!
  end

  def self.create_with_history_bulk(nodes, changeset)
    nodes.each do |node|
      node.version = 0
      node.visible = true
      changeset.update_bbox!(node.bbox)
    end
    save_with_history_bulk!(nodes, changeset)
  end

  def to_xml
    doc = OSM::API.new.get_xml_doc
    doc.root << to_xml_node
    doc
  end

  def to_xml_node(changeset_cache = {}, user_display_name_cache = {})
    el = XML::Node.new "node"
    el["id"] = id.to_s

    add_metadata_to_xml_node(el, self, changeset_cache, user_display_name_cache)

    if visible?
      el["lat"] = lat.to_s
      el["lon"] = lon.to_s
    end

    add_tags_to_xml_node(el, node_tags)

    el
  end

  def tags_as_hash
    tags
  end

  def tags
    @tags ||= Hash[node_tags.collect { |t| [t.k, t.v] }]
  end

  attr_writer :tags

  def add_tag_key_val(k, v)
    @tags ||= {}

    # duplicate tags are now forbidden, so we can't allow values
    # in the hash to be overwritten.
    raise OSM::APIDuplicateTagsError.new("node", id, k) if @tags.include? k

    @tags[k] = v
  end

  ##
  # are the preconditions OK? this is mainly here to keep the duck
  # typing interface the same between nodes, ways and relations.
  def preconditions_ok?
    in_world?
  end

  def self.preconditions_bulk_ok?(nodes)
    nodes.each do |node|
      raise OSM::APIPreconditionFailedError, "Node #{node.id} is not in the world" unless node.in_world?
    end
  end

  ##
  # dummy method to make the interfaces of node, way and relation
  # more consistent.
  def fix_placeholders!(_id_map, _placeholder_id = nil)
    # nodes don't refer to anything, so there is nothing to do here
  end

  private

  def save_with_history!
    t = Time.now.getutc

    self.version += 1
    self.timestamp = t

    Node.transaction do
      # clone the object before saving it so that the original is
      # still marked as dirty if we retry the transaction
      clone.save!

      # Create a NodeTag
      tags = self.tags
      NodeTag.where(:node_id => id).delete_all
      tags.each do |k, v|
        tag = NodeTag.new
        tag.node_id = id
        tag.k = k
        tag.v = v
        tag.save!
      end

      # Create an OldNode
      old_node = OldNode.from_node(self)
      old_node.timestamp = t
      old_node.save_with_dependencies!

      # tell the changeset we updated one element only
      changeset.add_changes! 1

      # save the changeset in case of bounding box updates
      changeset.save!
    end
  end

  class << self
    def save_with_history_bulk!(nodes, changeset, delete = false)
      t = Time.now.getutc
      Node.transaction do
        # clone the object before saving it so that the original is
        # still marked as dirty if we retry the transaction
        clones = nodes.collect do |node|
          node.version += 1
          node.timestamp = t
          node.update_tile
          node.skip_uniqueness = true
          node.clone
        end
        update_columns = if delete
                           [:changeset_id, :visible, :timestamp, :version]
                         else
                           [:latitude, :longitude, :changeset_id,
                            :visible, :timestamp, :tile, :version]
                         end
        Node.import(clones, :on_duplicate_key_update => update_columns)

        # Create a NodeTag
        node_ids = nodes.collect(&:id)
        NodeTag.where(:node_id => node_ids).delete_all
        tag_values = nodes.flat_map do |node|
          node.tags.collect do |k, v|
            nt = NodeTag.new(:node_id => node.id, :k => k, :v => v)
            nt.skip_uniqueness = true
            nt
          end
        end
        NodeTag.import!(tag_values)

        # Create OldNode
        old_nodes = nodes.collect do |node|
          old_node = OldNode.from_node(node)
          old_node.update_tile
          old_node
        end
        OldNode.save_with_dependencies_bulk!(old_nodes)

        # tell the changeset we updated one element only
        changeset.add_changes! nodes.length

        # save the changeset in case of bounding box updates
        changeset.save!
      end
    end
  end
end
