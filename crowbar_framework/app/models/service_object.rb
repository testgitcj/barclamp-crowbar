# Copyright 2011, Dell 
# 
# Licensed under the Apache License, Version 2.0 (the "License"); 
# you may not use this file except in compliance with the License. 
# You may obtain a copy of the License at 
# 
#  http://www.apache.org/licenses/LICENSE-2.0 
# 
# Unless required by applicable law or agreed to in writing, software 
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
# See the License for the specific language governing permissions and 
# limitations under the License. 
# 
# Author: RobHirschfeld 
# 
#
# Also functions as a data bag item wrapper as well.
#
require 'chef'
require 'json'

class ServiceObject

  extend CrowbarOffline

  def initialize(thelogger)
    @bc_name = bc_name
    @logger = thelogger
  end

  # OVERRIDE AS NEEDED! true if barclamp can have multiple proposals
  def self.allow_multiple_proposals?
    false
  end
  
  def self.bc_name
    self.name.underscore[/(.*)_service$/,1]
  end
  
  # ordered list of barclamps from groups in the crowbar.yml files.  
  # Built at barclamp install time by the catalog step
  def self.members
    cat = barclamp_catalog
    cat["barclamps"][bc_name].nil? ? [] : cat["barclamps"][bc_name]['members']
  end
  
  def self.barclamp_catalog
    YAML.load_file(File.join( 'config', 'catalog.yml'))
  end
  
  def self.all
    bc = {}
    ProposalObject.find("#{ProposalObject::BC_PREFIX}*").each do |bag|
      bc[bag.item.name[/#{ProposalObject::BC_PREFIX}(.*)/,1]] = bag.item[:description]
    end
    bc.delete_if { |k, v| bc.has_key? k[/^(.*)-(.*)/,0] }
    return bc
  end

  def self.run_order(bc, cat = nil)
    return 1000 if bc == nil
    cat = barclamp_catalog if cat.nil?
    order = (cat["barclamps"][bc]["order"] || 1000) rescue 1000
    (cat["barclamps"][bc]["run_order"] || order) rescue order
  end

  def run_order
    ServiceObject.run_order(@bc_name)
  end

  def self.chef_order(bc, cat = nil)
    return 1000 if bc == nil
    cat = barclamp_catalog if cat.nil?
    order = (cat["barclamps"][bc]["order"] || 1000) rescue 1000
    (cat["barclamps"][bc]["chef_order"] || order) rescue order
  end

  def chef_order
    ServiceObject.chef_order(@bc_name)
  end

  def random_password(size = 12)
    chars = (('a'..'z').to_a + ('0'..'9').to_a) - %w(i o 0 1 l 0)
    (1..size).collect{|a| chars[rand(chars.size)] }.join
  end

#
# Locking Routines
#
  def acquire_lock(name)
    @logger.debug("Acquire #{name} lock enter")
    f = File.new("tmp/#{name}.lock", File::RDWR|File::CREAT, 0644)
    @logger.debug("Acquiring #{name} lock")
    rc = false
    count = 0
    while rc == false do
      count = count + 1
      @logger.debug("Attempt #{name} Lock: #{count}")
      rc = f.flock(File::LOCK_EX|File::LOCK_NB)
      sleep 1 if rc == false
    end
    @logger.debug("Acquire #{name} lock exit: #{f.inspect}, #{rc}")
    f
  end

  def release_lock(f)
    @logger.debug("Release lock enter: #{f.inspect}")
    f.flock(File::LOCK_UN)
    f.close
    @logger.debug("Release lock exit")
  end

#
# Helper routines for queuing
#

  # Assumes the BA-LOCK is held
  def elements_not_ready(nodes, pre_cached_nodes = {})
    # Check to see if we should delay our commit until nodes are ready.
    delay = []
    nodes.each do |n|
      node = NodeObject.find_node_by_name(n)
      next if node.nil?
      
      pre_cached_nodes[n] = node
      delay << n if node.crowbar['state'] != "ready" and !delay.include?(n)
    end
    [ delay, pre_cached_nodes ]
  end

  def add_pending_elements(bc, inst, elements, queue_me, pre_cached_nodes = {})
    # Create map with nodes and their element list
    all_new_nodes = {}
    elements.each do |elem, nodes|
      nodes.each do |node|
        all_new_nodes[node] = [] if all_new_nodes[node].nil?
        all_new_nodes[node] << elem
      end
    end

    f = acquire_lock "BA-LOCK"
    delay = []
    pre_cached_nodes = {}
    begin
      # Check for delays and build up cache
      if queue_me
        delay = all_new_nodes.keys
      else
        delay, pre_cached_nodes = elements_not_ready(all_new_nodes.keys, pre_cached_nodes)
      end

      # Add the entries to the nodes.
      if delay.empty?
        all_new_nodes.each do |n, val|
          node = pre_cached_nodes[n]

          # Nothing to delay so mark them applying.
          node.crowbar['state'] = 'applying'
          node.crowbar['state_owner'] = "#{bc}-#{inst}"
          node.save
        end
      else
        all_new_nodes.each do |n, val|
          # Make sure we have a node.
          node = pre_cached_nodes[n]
          node = NodeObject.find_node_by_name(n) if node.nil?
          next if node.nil?
          pre_cached_nodes[n] = node

          # Make sure the node is allocated
          node.allocated = true
          node.crowbar["crowbar"]["pending"] = {} if node.crowbar["crowbar"]["pending"].nil?
          node.crowbar["crowbar"]["pending"]["#{bc}-#{inst}"] = val
          node.save
        end
      end
    rescue Exception => e
      @logger.fatal("add_pending_elements: Exception #{e.message} #{e.backtrace}")
    ensure
      release_lock f
    end

    [ delay, pre_cached_nodes ]
  end

  def remove_pending_elements(bc, inst, elements)
    # Create map with nodes and their element list
    all_new_nodes = {}
    elements.each do |elem, nodes|
      nodes.each do |node|
        all_new_nodes[node] = [] if all_new_nodes[node].nil?
        all_new_nodes[node] << elem
      end
    end

    # Remove the entries from the nodes.
    f = acquire_lock "BA-LOCK"
    begin
      all_new_nodes.each do |n,data|
        node = NodeObject.find_node_by_name(n)
        next if node.nil?
        unless node.crowbar["crowbar"]["pending"].nil? or node.crowbar["crowbar"]["pending"]["#{bc}-#{inst}"].nil?
          node.crowbar["crowbar"]["pending"]["#{bc}-#{inst}"] = {}
          node.save
        end
      end
    ensure
      release_lock f
    end
  end

  def restore_to_ready(nodes)
    f = acquire_lock "BA-LOCK"
    begin
      nodes.each do |n|
        node = NodeObject.find_node_by_name(n)
        next if node.nil?

        # Nothing to delay so mark them applying.
        node.crowbar['state'] = 'ready'
        node.crowbar['state_owner'] = ""
        node.save
      end
    ensure
      release_lock f
    end
  end

#
# Queuing routines:
#   queue_proposal - attempts to queue proposal returns delay otherwise.
#   dequeue_proposal - remove item from queue and clean up
#   process_queue - see what we can execute
#
  def queue_proposal(inst, elements, deps, bc = @bc_name)
    @logger.debug("queue proposal: enter #{inst} #{bc}")
    delay = []
    pre_cached_nodes = {}
    begin
      f = acquire_lock "queue"

      db = ProposalObject.find_data_bag_item "crowbar/queue"
      if db.nil?
        new_queue = Chef::DataBagItem.new
        new_queue.data_bag "crowbar"
        new_queue["id"] = "queue"
        new_queue["proposal_queue"] = []
        db = ProposalObject.new new_queue
      end

      queue_me = false
      db["proposal_queue"].each do |item|
        # Am I already in the queue
        if item["barclamp"] == bc and item["inst"] == inst
          nodes = []
          elements.each do |elem, inodes|
            inodes.each do |node|
              nodes << node unless nodes.include?(node)
            end
          end
          @logger.debug("queue proposal: exit #{inst} #{bc}: already queued")
          return [nodes, {}]
        end
      end

      # Make sure the deps if we aren't being queued.
      unless queue_me
        deps.each do |dep|
          prop = ProposalObject.find_proposal(dep["barclamp"], dep["inst"])

          # queue if prop doesn't exist
          queue_me = true if prop.nil?
          # queue if dep is queued
          queued = prop["deployment"][dep["barclamp"]]["crowbar-queued"] rescue false
          queue_me = true if queued
          # queue if dep has never run or failed
          success = (prop["deployment"][dep["barclamp"]]["crowbar-status"] == "success") rescue false
          queue_me = true unless success
        end
      end

      delay, pre_cached_nodes = add_pending_elements(bc, inst, elements, queue_me)
      return [ delay, pre_cached_nodes ] if delay.empty?

      db["proposal_queue"] << { "barclamp" => bc, "inst" => inst, "elements" => elements, "deps" => deps }
      db.save
    rescue Exception => e
      @logger.error("Error queuing proposal for #{bc}:#{inst}: #{e.message}")
    ensure
      release_lock f
    end

    prop = ProposalObject.find_proposal(bc, inst)
    prop["deployment"][bc]["crowbar-queued"] = true
    prop.save
    @logger.debug("queue proposal: exit #{inst} #{bc}")
    [ delay, pre_cached_nodes ]
  end

  def dequeue_proposal_no_lock(queue, inst, bc = @bc_name)
    @logger.debug("dequeue_proposal_no_lock: enter #{inst} #{bc}")
    begin
      elements = nil
      # The elements = item["elements"] is on purpose to get the assignment out of the element.
      queue.delete_if { |item| item["barclamp"] == bc and item["inst"] == inst and ((elements = item["elements"]) or true)}

      remove_pending_elements(bc, inst, elements) if elements

      prop = ProposalObject.find_proposal(bc, inst)
      unless prop.nil?
        prop["deployment"][bc]["crowbar-queued"] = false
        prop.save
      end
    rescue Exception => e
      @logger.error("Error dequeuing proposal for #{bc}:#{inst}: #{e.message} #{e.backtrace}")
      @logger.debug("dequeue proposal_no_lock: exit #{inst} #{bc}: error")
      return false
    end
    @logger.debug("dequeue proposal_no_lock: exit #{inst} #{bc}")
    true
  end

  def dequeue_proposal(inst, bc = @bc_name)
    @logger.debug("dequeue proposal: enter #{inst} #{bc}")
    ret = false
    begin
      f = acquire_lock "queue"

      db = ProposalObject.find_data_bag_item "crowbar/queue"
      @logger.debug("dequeue proposal: exit #{inst} #{bc}: no entry") if db.nil?
      return true if db.nil?

      queue = db["proposal_queue"]
      ret = dequeue_proposal_no_lock(queue, inst, bc)
      db.save if ret
    rescue Exception => e
      @logger.error("Error dequeuing proposal for #{bc}:#{inst}: #{e.message} #{e.backtrace}")
      @logger.debug("dequeue proposal: exit #{inst} #{bc}: error")
      return ret
    ensure
      release_lock f
    end
    @logger.debug("dequeue proposal: exit #{inst} #{bc}")
    ret
  end

  #
  # NOTE: If dependencies don't form a DAG (Directed Acyclic Graph) then we have a problem
  # with our dependency algorithm
  #
  def process_queue
    @logger.debug("process queue: enter")
    loop_again = true
    while loop_again
      loop_again = false
      list = []
      begin
        f = acquire_lock "queue"

        db = ProposalObject.find_data_bag_item "crowbar/queue"
        if db.nil?
          @logger.debug("process queue: exit: queue gone")
          return
        end

        queue = db["proposal_queue"]
        if queue.nil? or queue.empty?
          @logger.debug("process queue: exit: empty queue")
          return
        end

        @logger.debug("process queue: queue: #{queue.inspect}")

        # Test for ready
        remove_list = []
        queue.each do |item|
          prop = ProposalObject.find_proposal(item["barclamp"], item["inst"])
          if prop.nil?
            remove_list << item
            next
          end

          queue_me = false
          # Make sure the deps if we aren't being queued.
          item["deps"].each do |dep|
            depprop = ProposalObject.find_proposal(dep["barclamp"], dep["inst"])
  
            # queue if depprop doesn't exist
            queue_me = true if depprop.nil?
            # queue if dep is queued
            queued = depprop["deployment"][dep["barclamp"]]["crowbar-queued"] rescue false
            queue_me = true if queued
            # queue if dep has never run or failed
            success = (depprop["deployment"][dep["barclamp"]]["crowbar-status"] == "success") rescue false
            queue_me = true unless success
          end
          next if queue_me

          # Create map with nodes and their element list
          all_new_nodes = {}
          prop["deployment"][item["barclamp"]]["elements"].each do |elem, nodes|
            nodes.each do |node|
              all_new_nodes[node] = [] if all_new_nodes[node].nil?
              all_new_nodes[node] << elem
            end
          end
          delay, pre_cached_nodes = elements_not_ready(all_new_nodes.keys)
          list << item if delay.empty?
        end

        save_db = false
        remove_list.each do |iii| 
          save_db |= dequeue_proposal_no_lock(db["proposal_queue"], iii["inst"], iii["barclamp"])
        end

        list.each do |iii| 
          save_db |= dequeue_proposal_no_lock(db["proposal_queue"], iii["inst"], iii["barclamp"])
        end
      
        db.save if save_db

      rescue Exception => e
        @logger.error("Error processing queue: #{e.message}")
        @logger.debug("process queue: exit: error")
        return
      ensure
        release_lock f
      end

      @logger.debug("process queue: list: #{list.inspect}")

      # For each ready item, apply it.
      list.each do |item|
        @logger.debug("process queue: item to do: #{item.inspect}")
        bc = item["barclamp"]
        inst = item["inst"]
        service = eval("#{bc.camelize}Service.new @logger")
        answer = service.proposal_commit(inst, true)
        @logger.debug("process queue: item #{item.inspect}: results #{answer.inspect}")
        loop_again = true if answer[0] != 202
        $htdigest_reload = true
      end
      @logger.debug("process queue: exit")
    end
  end

#
# update proposal status information
#
  def update_proposal_status(inst, status, message, bc = @bc_name)
    @logger.debug("update_proposal_status: enter #{inst} #{bc} #{status} #{message}")

    prop = ProposalObject.find_proposal(bc, inst)
    unless prop.nil?
      prop["deployment"][bc]["crowbar-status"] = status
      prop["deployment"][bc]["crowbar-failed"] = message
      res = prop.save
    else
      res = true
    end

    @logger.debug("update_proposal_status: exit #{inst} #{bc} #{status} #{message}")
    res
  end

  def bc_name=(new_name)
    @bc_name = new_name
  end
  
  def bc_name 
    @bc_name
  end
  
  def initialize(thelogger)
    @bc_name = "unknown"
    @logger = thelogger
  end

#
# API Functions
#
  def versions
    [200, { :versions => [ "1.0" ] }]
  end

  def transition
    [200, {}]
  end

  def list_active
    roles = RoleObject.find_roles_by_name("#{@bc_name}-config-*")
    roles.map! { |r| r.name.gsub("#{@bc_name}-config-","") } unless roles.empty?
    [200, roles]
  end

  def show_active(inst)
    inst = "#{@bc_name}-config-#{inst}"

    role = RoleObject.find_role_by_name(inst)
    
    if role.nil?
      [404, "Active instance not found"]
    else
      [200, role]
    end
  end

  def clean_proposal(proposal)
    proposal.delete("controller")
    proposal.delete("action")
    proposal.delete("barclamp")
    proposal.delete("name")
    proposal.delete("_method")
    proposal.delete("authenticity_token")
  end

  #
  # Proposal is a json structure (not a ProposalObject)
  # Use to create or update an active instance
  #
  def active_update(proposal, inst, in_queue)
    begin
      role = ServiceObject.proposal_to_role(proposal, @bc_name)
      clean_proposal(proposal)
      validate_proposal proposal
      apply_role(role, inst, in_queue)
    rescue Net::HTTPServerException => e
      [e.response.code, {}]
    rescue Chef::Exceptions::ValidationFailed => e2
      [400, e2.message]
    end
  end

  def destroy_active(inst)
    inst = "#{@bc_name}-config-#{inst}"
    @logger.debug "Trying to deactivate role #{inst}" 
    role = RoleObject.find_role_by_name(inst)
    if role.nil?
      [404, {}]
    else
      # By nulling the elements, it functions as a remove
      dep = role.override_attributes
      dep[@bc_name]["elements"] = {}      
      @logger.debug "#{inst} proposal has a crowbar-committing key" if dep[@bc_name]["config"].has_key? "crowbar-committing"
      dep[@bc_name]["config"].delete("crowbar-committing")
      dep[@bc_name]["config"].delete("crowbar-queued")
      role.override_attributes = dep
      answer = apply_role(role, inst, false)
      role.destroy
      answer
    end
  end

  def elements
    roles = RoleObject.find_roles_by_name("#{@bc_name}-*")
    cull_roles = RoleObject.find_roles_by_name("#{@bc_name}-config-*")
    roles.delete_if { |r| cull_roles.include?(r) } unless roles.empty?
    roles.map! { |r| r.name } unless roles.empty?
    [200, roles]
  end

  def element_info
    nodes = NodeObject.find_all_nodes
    nodes.map! { |n| n.name } unless nodes.empty?
    [200, nodes]
  end

  def proposals_raw
    ProposalObject.find_proposals(@bc_name)
  end 
  
  def proposals
    props = proposals_raw
    props.map! { |p| p["id"].gsub("bc-#{@bc_name}-", "") } unless props.empty?
    [200, props]
  end

  def proposal_show(inst)
    prop = ProposalObject.find_proposal(@bc_name, inst)
    if prop.nil?
      [404, {}]
    else
      [200, prop]
    end
  end

  #
  # This can be overridden to provide a better creation proposal
  #
  def create_proposal
    prop = ProposalObject.find_proposal("template", @bc_name)
    prop.raw_data
  end

  def proposal_create(params)
    base_id = params["id"]
    params["id"] = "bc-#{@bc_name}-#{params["id"]}"

    prop = ProposalObject.find_proposal(@bc_name, base_id)
    return [400, I18n.t('.name_exists', :scope=>'model.service')] unless prop.nil?
    return [400, I18n.t('.too_short', :scope=>'model.service')] if base_id.length == 0
    return [400, I18n.t('.illegal_chars', :scope=>'model.service')] if base_id =~ /[^A-Za-z0-9_]/

    base = create_proposal
    base["deployment"][@bc_name]["config"]["environment"] = "#{@bc_name}-config-#{base_id}"
    proposal = base.merge(params)
    clean_proposal(proposal)
    _proposal_update proposal
  end

  def proposal_edit(params)
    params["id"] = "bc-#{@bc_name}-#{params["id"]}"
    proposal = {}.merge(params)
    clean_proposal(proposal)
    _proposal_update proposal
  end

  def proposal_delete(inst)
    prop = ProposalObject.find_proposal(@bc_name, inst)
    if prop.nil?
      [404, {}]
    else
      prop.destroy
      [200, {}]
    end
  end

  def proposal_commit(inst, in_queue = false)
    prop = ProposalObject.find_proposal(@bc_name, inst)

    if prop.nil?
      [404, "#{I18n.t('.cannot_find', :scope=>'model.service')}: #{@bc_name}.#{inst}"]
    elsif prop["deployment"][@bc_name]["crowbar-committing"]
      [402, "#{I18n.t('.already_commit', :scope=>'model.service')}: #{@bc_name}.#{inst}"]
    else
      # Put mark on the wall
      prop["deployment"][@bc_name]["crowbar-committing"] = true
      prop.save

      answer = active_update prop.raw_data, inst, in_queue

      # Unmark the wall
      prop = ProposalObject.find_proposal(@bc_name, inst)
      prop["deployment"][@bc_name]["crowbar-committing"] = false
      prop.save

      answer
    end
  end

  #
  # This can be overridden.  Specific to node validation.
  #
  def validate_proposal_elements proposal_elements
      proposal_elements.each do |role_and_elements|
          elements = role_and_elements[1]
          uniq_elements = elements.uniq
          if uniq_elements.length != elements.length
              raise  I18n.t('proposal.failures.duplicate_elements_in_role')+" "+role_and_elements[0]
          end
          uniq_elements.each do |node_name|
              nodes = NodeObject.find_nodes_by_name node_name
              if 0 == nodes.length
                  raise  I18n.t('proposal.failures.unknown_node')+" "+node_name
              end
          end
      end
  end

  #
  # This can be overridden to get better validation if needed.
  #
  def validate_proposal proposal
    path = "/opt/dell/chef/data_bags/crowbar"
    path = "schema" unless CHEF_ONLINE
    validator = CrowbarValidator.new("#{path}/bc-template-#{@bc_name}.schema")
    Rails.logger.info "validating proposal #{@bc_name}"
    
    errors = validator.validate(proposal)
    if errors && !errors.empty?
      strerrors = ""
      errors.each do |e|
        strerrors += "#{e.message}\n"
      end
      Rails.logger.info "validation errors in proposal #{@bc_name}"
      raise Chef::Exceptions::ValidationFailed.new(strerrors)
    end
  end

  def _proposal_update(proposal)
    data_bag_item = Chef::DataBagItem.new

    begin 
      data_bag_item.raw_data = proposal
      data_bag_item.data_bag "crowbar"

      validate_proposal proposal

      prop = ProposalObject.new data_bag_item
      prop.save
      Rails.logger.info "saved proposal"
      [200, {}]
    rescue Net::HTTPServerException => e
      [e.response.code, {}]
    rescue Chef::Exceptions::ValidationFailed => e2
      [400, e2.message]
    end
  end

  #
  # This is a role output function
  # Can take either a RoleObject or a Role.
  #
  def self.role_to_proposal(role, bc_name)
    proposal = {}

    proposal["id"] = role.name.gsub("#{bc_name}-config-", "bc-#{bc_name}-")
    proposal["description"] = role.description
    proposal["attributes"] = role.default_attributes
    proposal["deployment"] = role.override_attributes

    proposal
  end

  #
  # From a proposal json
  #
  def self.proposal_to_role(proposal, bc_name)
    role = Chef::Role.new
    role.name proposal["id"].gsub("bc-#{bc_name}-", "#{bc_name}-config-")
    role.description proposal["description"]
    role.default_attributes proposal["attributes"]
    role.override_attributes proposal["deployment"]
    RoleObject.new role
  end

  #
  # After validation, this is where the role is applied to the system
  # The old instance (if one exists) is compared with the new instance.
  # roles are removed and delete roles are added (if they exist) for nodes leaving roles
  # roles are added for nodes joining roles.
  # Calls chef-client on nodes
  #
  # This function can be overriden to define a barclamp specific operation.
  # A call is provided that receives the role and all string names of the nodes before the chef-client call
  #
  def apply_role(role, inst, in_queue)
    # Query for this role
    old_role = RoleObject.find_role_by_name(role.name)

    nodes = {}

    # Get the new elements list
    new_deployment = role.override_attributes[@bc_name]
    new_elements = new_deployment["elements"]
    element_order = new_deployment["element_order"]

    # 
    # Attempt to queue the propsal.  If delay is empty, then run it.
    #
    deps = proposal_dependencies(role)
    delay, pre_cached_nodes = queue_proposal(inst, new_elements, deps)
    return [202, delay] unless delay.empty?

    # make sure the role is saved
    role.save

    # Build a list of old elements
    old_elements = {}
    old_deployment = old_role.override_attributes[@bc_name] unless old_role.nil?
    old_elements = old_deployment["elements"] unless old_deployment.nil?
    element_order = old_deployment["element_order"] if (!old_deployment.nil? and element_order.nil?)

    # For Role ordering
    local_chef_order = chef_order()
    role_map = new_deployment["element_states"]
    role_map = {} unless role_map

    # Merge the parts based upon the element install list.
    all_nodes = []
    run_order = []
    element_order.each do | elems |
      r_nodes = []
      elems.each do |elem|
        old_nodes = old_elements[elem]
        new_nodes = new_elements[elem]

        unless old_nodes.nil?
          elem_remove = nil
          tmprole = RoleObject.find_role_by_name "#{elem}_remove"
          unless tmprole.nil?
            elem_remove = tmprole.name
          end

          old_nodes.each do |n|
            if new_nodes.nil? or !new_nodes.include?(n)
              nodes[n] = { :remove => [], :add => [] } if nodes[n].nil?
              nodes[n][:remove] << elem 
              nodes[n][:add] << elem_remove unless elem_remove.nil?
              r_nodes << n
            end
          end
        end

        unless new_nodes.nil?
          new_nodes.each do |n|
            all_nodes << n unless all_nodes.include?(n)
            if old_nodes.nil? or !old_nodes.include?(n)
              nodes[n] = { :remove => [], :add => [] } if nodes[n].nil?
              nodes[n][:add] << elem
            end
            r_nodes << n unless r_nodes.include?(n)
          end
        end
      end
      run_order << r_nodes unless r_nodes.empty?
    end

    # Clean the run_lists
    admin_nodes = []
    nodes.each do |n, lists|
      node = pre_cached_nodes[n]
      node = NodeObject.find_node_by_name(n) if node.nil?
      next if node.nil?

      admin_nodes << n if node.admin?

      save_it = false

      rlist = lists[:remove]
      alist = lists[:add]

      # Remove the roles being lost
      rlist.each do |item|
        next unless node.role? item
        @logger.debug("AR: Removing role #{item} to #{node.name}")
        node.delete_from_run_list item
        save_it = true
      end

      # Add the roles being gained
      alist.each do |item|
        next if node.role? item
        @logger.debug("AR: Adding role #{item} to #{node.name}")
        node.add_to_run_list(item, local_chef_order, role_map[item])
        save_it = true
      end

      # Make sure the config role is on the nodes in this barclamp, otherwise remove it
      if all_nodes.include?(node.name)
        # Add the config role 
        unless node.role?(role.name)
          @logger.debug("AR: Adding role #{role.name} to #{node.name}")
          node.add_to_run_list(role.name, local_chef_order, role_map[role.name])
          save_it = true
        end
      else
        # Remove the config role 
        if node.role?(role.name)
          @logger.debug("AR: Removing role #{role.name} to #{node.name}")
          node.delete_from_run_list role.name
          save_it = true
        end
      end

      @logger.debug("AR: Saving node #{node.name}") if save_it
      node.save if save_it
    end

    apply_role_pre_chef_call(old_role, role, all_nodes)

    # Each batch is a list of nodes that can be done in parallel.
    ran_admin = false
    run_order.each do | batch |
      next if batch.empty?
      snodes = []
      admin_list = []
      batch.each do |n|
        # Run admin nodes a different way.
        if admin_nodes.include?(n)
          admin_list << n
          ran_admin = true
          next
        end
        snodes << n
      end
 
      @logger.debug("AR: Calling knife for #{role.name} on non-admin nodes #{snodes.join(" ")}")
      @logger.debug("AR: Calling knife for #{role.name} on admin nodes #{admin_list.join(" ")}")

      # Only take the actions if we are online
      if CHEF_ONLINE
        # 
        # XXX: We used to do this twice - do we really need twice???
        # Yes! We do!  The system has some transient issues that are hidden
        # but the double run for failing nodes.  For now, we will do this.
        # Make this better one day.
        #
        pids = {}
        unless snodes.empty?
          snodes.each do |node|
            filename = "log/#{node}.chef_client.log"
            pid = run_remote_chef_client(node, "chef-client", filename)
            pids[pid] = node
          end
          status = Process.waitall
          badones = status.select { |x| x[1].exitstatus != 0 }

          unless badones.empty?
            badones.each do |baddie|
              node = pids[baddie[0]]
              @logger.warn("Re-running chef-client again for a failure: #{node} #{@bc_name} #{inst}")
              filename = "log/#{node}.chef_client.log"
              pid = run_remote_chef_client(node, "chef-client", filename)
              pids[pid] = node
            end
            status = Process.waitall
            badones = status.select { |x| x[1].exitstatus != 0 }

            unless badones.empty?
              message = "Failed to apply the proposal to: "
              badones.each do |baddie|
                message = message + "#{pids[baddie[0]]} "
              end
              update_proposal_status(inst, "failed", message)
              restore_to_ready(all_nodes)
              process_queue unless in_queue
              return [ 405, message ] 
            end
          end
        end

        unless admin_list.empty?
          admin_list.each do |node|
            filename = "log/#{node}.chef_client.log"
            pid = run_remote_chef_client(node, "/opt/dell/bin/single_chef_client.sh", filename)
            pids[node] = pid
          end
          status = Process.waitall
          badones = status.select { |x| x[1].exitstatus != 0 }

          unless badones.empty?
            badones.each do |baddie|
              node = pids[baddie[0]]
              @logger.warn("Re-running chef-client (admin) again for a failure: #{node} #{@bc_name} #{inst}")
              filename = "log/#{node}.chef_client.log"
              pid = run_remote_chef_client(node, "/opt/dell/bin/single_chef_client.sh", filename)
              pids[pid] = node
            end
            status = Process.waitall
            badones = status.select { |x| x[1].exitstatus != 0 }

            unless badones.empty?
              message = "Failed to apply the proposal to: "
              badones.each do |baddie|
                message = message + "#{pids[baddie[0]]} "
              end
              update_proposal_status(inst, "failed", message)
              restore_to_ready(all_nodes)
              process_queue unless in_queue
              return [ 405, message ] 
            end
          end
        end
      end
    end

    # XXX: This should not be done this way.  Something else should request this.
    system("sudo -i /opt/dell/bin/single_chef_client.sh") if CHEF_ONLINE and !ran_admin

    update_proposal_status(inst, "success", "")
    restore_to_ready(all_nodes)
    process_queue unless in_queue
    [200, {}]
  end

  def apply_role_pre_chef_call(old_role, role, all_nodes)
    # noop by default.
  end

  #
  # Inputs: role = RoleObject of proposal being applied/queued.
  # Returns: List of hashs { "barclamp" => bcname, "inst" => instname }
  #
  def proposal_dependencies(role)
    # Default none
    []
  end

  def add_role_to_instance_and_node(barclamp, instance, name, prop, role, newrole)
    node = NodeObject.find_node_by_name name    
    if node.nil?
      @logger.debug("ARTOI: couldn't find node #{name}. bailing")
      return false 
    end

    local_chef_order = ServiceObject.chef_order(barclamp)
    role_map = prop["deployment"][barclamp]["element_states"] rescue {}
    role_map = {} unless role_map

    prop["deployment"][barclamp]["elements"][newrole] = [] if prop["deployment"][barclamp]["elements"][newrole].nil?
    unless prop["deployment"][barclamp]["elements"][newrole].include?(node.name)
      @logger.debug("ARTOI: updating proposal with node #{node.name}, role #{newrole} for deployment of #{barclamp}")
      prop["deployment"][barclamp]["elements"][newrole] << node.name
      prop.save
    else
      @logger.debug("ARTOI: node #{node.name} already in proposal: role #{newrole} for #{barclamp}")
    end

    role.override_attributes[barclamp]["elements"][newrole] = [] if role.override_attributes[barclamp]["elements"][newrole].nil?
    unless role.override_attributes[barclamp]["elements"][newrole].include?(node.name)
      @logger.debug("ARTOI: updating role #{role.name} for node #{node.name} for barclamp: #{barclamp}/#{newrole}")
      role.override_attributes[barclamp]["elements"][newrole] << node.name
      role.save
    else
      @logger.debug("ARTOI: role #{role.name} already has node #{node.name} for barclamp: #{barclamp}/#{newrole}")
    end

    save_it = false
    unless node.role?(newrole)
      node.add_to_run_list(newrole, local_chef_order, role_map[newrole])
      save_it = true
    end

    unless node.role?("#{barclamp}-config-#{instance}")
      node.add_to_run_list("#{barclamp}-config-#{instance}", local_chef_order)
      save_it = true
    end

    if save_it
      @logger.debug("saving node")
      node.save 
    end
    true
  end

  #
  # fork and exec ssh call to node and return pid.
  #
  def run_remote_chef_client(node, command, logfile_name)
    Kernel::fork {
      # Make sure all file descriptors are closed
      ObjectSpace.each_object(IO) do |io|
        unless [STDIN, STDOUT, STDERR].include?(io)
          begin
            unless io.closed?
              io.close
            end
          rescue ::Exception
          end
        end
      end

      # Fix the normal file descriptors.
      begin; STDIN.reopen "/dev/null"; rescue ::Exception; end       
      if logfile_name
        begin
          STDOUT.reopen logfile_name, "a+"
          File.chmod(0644, logfile_name)
          STDOUT.sync = true
        rescue ::Exception
          begin; STDOUT.reopen "/dev/null"; rescue ::Exception; end
        end
      else
        begin; STDOUT.reopen "/dev/null"; rescue ::Exception; end
      end
      begin; STDERR.reopen STDOUT; rescue ::Exception; end
      STDERR.sync = true      

      # Exec command
      # the -- tells sudo to stop interpreting options
      exec("sudo -i -u root -- ssh root@#{node} #{command}")
    }
  end


end

