module Myumbc3
  module Importer
    module GroupImporter
      
      API_URL = 'https://dev.my.umbc.edu/admin/export/groups.json'
      
      def self.reset
        Group.delete_all
      end
      
      def self.dump(id)
        ht = RestClient.post API_URL, key: UMBC_CONFIG[:myumbc3][:importer][:passkey], ids: id
        js = JSON.parse(ht.to_str, symbolize_names: true).first
        out = JSON.pretty_generate(js)
        
        output_file = File.new("tmp/group-#{js[:id]}.json", 'w')
        output_file << out
        output_file.close
      end
    
      @entity_cache = {}
    
      def self.entity_cache(my3_id)
        if !@entity_cache[my3_id]
          @entity_cache[my3_id] = Entity.find_by_slug(my3_id)
        end
        @entity_cache[my3_id]
      end
    
      def self.import(output_file)
        self.reset
        page_number = 1
        page_size = 10
        total_import_count = 0
          
        begin
          Rails.logger.info "Batch #{page_number}: Requesting #{page_size} groups from my3..."
          
          ht = RestClient.post API_URL, key: UMBC_CONFIG[:myumbc3][:importer][:passkey], page: page_number, page_size: page_size
          group_data = JSON.parse(ht.to_str, symbolize_names: true)
          
          Rails.logger.info "Batch #{page_number}: Parsing #{group_data.length} returned groups..."
      
          batch_import_count = 0

          group_data.each do |old_group|
            new_group = Group.new
            
            # Status
            if old_group[:kind] == 'retired'
              new_group.status = :retired
            elsif old_group[:status] == 'active'
              new_group.status = :active
            elsif (old_group[:status] == 'inactive') && (old_group[:token].match(/denied/))
              new_group.status = :denied
            elsif old_group[:status] == 'pending'
              new_group.status = :pending
            else
              raise "Unknown status, for #{old_group[:token]}:#{old_group[:id]} -- #{old_group[:status]}"
            end
            
            # Slug
            new_group.slugs.add "my3-group-#{old_group[:id]}"
            if new_group.status == :active
              new_group.slug = old_group[:token]
            end
            
            new_group.name = old_group[:name]
            new_group.tagline = Utils::Text.to_plain_text(old_group[:tagline])
            new_group.description = Utils::Text.to_plain_text(old_group[:description])
            new_group.analytics_id = old_group[:google_analytics_id]
            
            
            
            # Creation
            new_group.created_at = old_group[:created_at]
            new_group.created_by = Entity.get("my3-user-#{old_group[:created_by_id]}")
            
            # Kind
            new_group.kind = (old_group[:kind] == 'retired') ? :legacy : old_group[:kind].to_sym
            # TODO Map these to new kinds?
            
            # Access
            public = old_group[:public] == true
            open = old_group[:membership] == 'open'

            if public
              #new_group.visbility.add('public')
            end
            
            #####
            # Tools -> Categories
            old_group[:group_tools].sort_by { |t| t[:position] }.each do |tool|
              
              if tool[:write_access] == 'admin'
                posting = :admins
              elsif open && (tool[:write_access] == 'member')
                posting = :open
              elsif public && !open
                posting = :members
              elsif !public
                posting = :members
              else
                raise "Unknown posting scenario"
              end
              
              # if public && (tool[:read_access] != 'anyone')
              #   raise "Take a look at group #{old_group[:token]}:#{old_group[:id]} for tools"
              # end
              
              case tool[:kind]
              when 'home'
                # Ignore
              when 'news'
                if tool[:enabled] == true
                  new_group.posts.categories.add('News', format: :list, posting: posting)
                end
                new_group.posts.posting = posting
              when 'events'
                new_group.events.posting = posting
              when 'discussions'
                if tool[:enabled] == true
                  new_group.posts.categories.add('Discussions', format: :forum, posting: posting)
                end
              when 'media'
                if tool[:enabled] == true
                  new_group.posts.categories.add('Media', format: :gallery, posting: posting)
                end
              when 'documents'
                new_group.library.posting = posting
              when 'members'
                if tool[:read_access] == 'anyone'
                  new_group.show_members = :anyone
                else
                  new_group.show_members = :members
                end
              when 'settings'
                # Ignore
              when 'spotlights'
                new_group.posts.categories.add('Spotlights Archive', format: :list, posting: posting)
              when 'statuses'
                # Ignore
              end
            end
            
            # Documents
            old_group[:group_document_folders].each do |f|
              new_group.library.folders.add(f[:title])
            end
            
            
            # Group Memberships
            old_group[:group_members].each do |gm|
              e = self.entity_cache("my3-user-#{gm[:user_id]}")
              
              if e.present?
                nots = (gm[:watching] ? 'important' : 'none')
              
                if gm[:status] == 'invited'
                  
                  #new_gm = GroupInvitation.new
                  #new_gm.entity_id = e.id
                  #new_gm.created_at = gm[:invited_at]
                  creator = self.entity_cache("my3-user-#{gm[:invited_by_id]}")
                  raise "Could not find creator: #{gm[:invited_by_id]}" if creator.nil?
                  #new_gm.created_by_id = creator.id
                  
                  new_group.invitations.add(e, { created_at: gm[:invited_at], created_by: creator })
                else
                  case gm[:role]
                  when 'owner', 'admin', 'member'
                    #is_admin = ((gm[:role] == 'owner') || (gm[:role] == 'admin'))
                    #new_gm = GroupMembership.new
                    #new_gm.entity_id = e.id
                    #new_gm.notifications = nots
                    #new_gm.admin = ((gm[:role] == 'owner') || (gm[:role] == 'admin'))
                    #new_gm.locked = gm[:auto]
                    #new_gm.title = gm[:custom_title]
                    #new_gm.email = gm[:custom_email]
                    #new_gm.created_at = gm[:joined_at]
                    creator = self.entity_cache("my3-user-#{gm[:joined_by_id]}")
                    raise "Could not find creator: #{gm[:joined_by_id]}" if creator.nil?
                    #new_gm.created_by_id = creator.id
                    new_group.memberships.add(e, { created_at: gm[:joined_at], notifications: nots, admin: ((gm[:role] == 'owner') || (gm[:role] == 'admin')), locked: gm[:auto], title: gm[:title], email: gm[:email], created_by: creator})
                  when 'follower'
                    #new_gm = GroupFollowership.new
                    #new_gm.entity_id = e.id
                    #new_gm.notifications = nots
                    #new_gm.created_at = gm[:joined_at]
                    #new_gm.created_by_id = e.id
                    new_group.followerships.add(e, { notifications: nots, created_at: gm[:joined_at], created_by: e })
                  end
                end
                
                #if new_gm && !new_gm.valid?
                #  raise "#{new_gm.errors.messages}"
                #  raise "BAD: Group: #{old_group[:id]}, Entity: #{gm[:user_id]} / #{gm[:role]}"
                #end
                
                #new_group.group_relationships << new_gm
              end
            end
            
            #ap old_group
            #puts "#{new_group.name}"
            new_group.save!
            
            batch_import_count += 1
            total_import_count += 1
          end 

          Rails.logger.info "Batch #{page_number}: Added #{batch_import_count} groups... TOTAL: #{total_import_count}"
          page_number += 1
          
        end while group_data.present?
        
        Rails.logger.info "IMPORTED: #{total_import_count} groups."
      end  
    end
  end
end