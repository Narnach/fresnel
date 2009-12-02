require File.dirname(Pathname.new(__FILE__).realpath) + "/lighthouse"
require File.dirname(Pathname.new(__FILE__).realpath) + "/date_parser"
require File.dirname(Pathname.new(__FILE__).realpath) + "/cache"
require File.dirname(Pathname.new(__FILE__).realpath) + "/color"
require File.dirname(Pathname.new(__FILE__).realpath) + "/setup_wizard"
require File.dirname(Pathname.new(__FILE__).realpath) + "/frame"



require 'active_support'
require 'terminal-table/import'
require 'highline/import'

class String
  def wrap(col = 80)
    self.gsub(/(.{1,#{col}})( +|$\n?)|(.{1,#{col}})/,
      "\\1\\3\n")
  end
end

class Fresnel
  attr_reader :global_config_file, :project_config_file, :app_description
  attr_accessor :lighthouse, :current_project_id, :cache, :cache_timeout

  def initialize(options=Hash.new)
    @global_config_file="#{ENV['HOME']}/.fresnel"
    @project_config_file=File.expand_path('.fresnel')
    @app_description="A lighthouseapp console manager"
    @lighthouse=Lighthouse
    @cache=Cache.new(:active=>options[:cache]||false, :timeout=>options[:cache_timeout]||5.minutes)
    Lighthouse.account, Lighthouse.token = load_global_config
    @current_project_id=load_project_config
  end

  def load_global_config
    if File.exists? self.global_config_file
      config = YAML.load_file(self.global_config_file)
      if config && config.class==Hash && config.has_key?('account') && config.has_key?('token')
        return [config['account'], config['token']]
      else
        puts Frame.new(:header=>"Warning !",:body=>"global config did not validate , recreating")
        SetupWizard.global(self)
        load_global_config
      end
    else
      puts Frame.new(:header=>"Notice",:body=>"global config not found at #{self.global_config_file}, starting wizard")
      SetupWizard.global(self)
      load_global_config
    end
  end

  def load_project_config
    if File.exists? self.project_config_file
      config = YAML.load_file(self.project_config_file)
      if config && config.class==Hash && config.has_key?('project_id')
        return config['project_id']
      else
        puts Frame.new(:header=>"Warning !",:body=>"project config found but project_id was not declared")
        load_project_config
      end
    else
      puts Frame.new(:header=>"Notice",:body=>"project config not found at #{self.global_config_file}, starting wizard")
      SetupWizard.project(self)
      load_project_config
    end
  end

  def account
    lighthouse.account
  end

  def token
    lighthouse.token
  end

  def projects(options=Hash.new)
    options[:object]||=false
    puts "fetching projects..."
    projects_data=cache.load(:name=>"fresnel_projects",:action=>"Lighthouse::Project.find(:all)")
    project_table = table do |t|
      t.headings = ['id', 'project name', 'public', 'open tickets']

      projects_data.each do |project|
        t << [{:value=>project.id, :alignment=>:right}, project.name, project.public, {:value=>project.open_tickets_count, :alignment=>:right}]
      end
    end
    options[:object] ? projects_data : puts(project_table)
  end

  def tickets
    if self.current_project_id
      tickets=cache.load(:name=>"fresnel_project_#{self.current_project_id}_tickets", :action=>"Lighthouse::Project.find(#{self.current_project_id}).tickets")
      if tickets.any?
        tickets_table = table do |t|
          t.headings = [
            {:value=>'#',:alignment=>:center},
            {:value=>'state',:alignment=>:center},
            {:value=>Color.print('title'),:alignment=>:center},
            {:value=>Color.print('tags'),:alignment=>:center},
            {:value=>'by',:alignment=>:center},
            {:value=>'assigned to',:alignment=>:center},
            'created at',
            'updated at'
          ]

          tickets.sort_by(&:number).reverse.each do |ticket|
            t << [
              {:value=>ticket.number, :alignment=>:right},
              {:value=>ticket.state,:alignment=>:center},
              "#{ticket.title.strip[0..50]}#{"..." if ticket.title.size>50}",
              ticket.tag,
              ticket.creator_name,
              (ticket.assigned_user_name rescue "nobody"),
              {:value=>DateParser.string(ticket.created_at.to_s), :alignment=>:right},
              {:value=>DateParser.string(ticket.updated_at.to_s), :alignment=>:right}
            ]
          end
        end
        puts tickets_table
      else
        puts Frame.new(:header=>"Notice",:body=>"no tickets found yet...")
      end
    else
      puts Frame.new(:header=>"Error",:body=>"We have no project id o.O")
    end
  end

  def show_ticket(number)

    ticket = cache.load(:name=>"fresnel_ticket_#{number}",:action=>"Lighthouse::Ticket.find(#{number}, :params => { :project_id => #{self.current_project_id} })")
    puts Frame.new(
      :header=>[
        "Ticket ##{number} : #{ticket.title.chomp}",
        "Date : #{DateParser.string(ticket.created_at.to_s)} by #{ticket.creator_name}",
        "Tags : #{ticket.tag}"
      ],
      :body=>ticket.versions.first.body
    )


    ticket.versions.each do |v|
      next if v.body==ticket.versions.first.body
      if v.body.nil?
        puts "  State changed on #{DateParser.string(v.created_at.to_s)} to : #{v.state} by #{v.user_name}"
      else
        user_date=v.user_name.capitalize
        date=DateParser.string(v.created_at.to_s)
        user_date=user_date.ljust((TERM_SIZE-5)-date.size)
        user_date+=date

        puts Frame.new(:header=>user_date,:body=>v.body)
      end
    end
  end

  def comment(number)
    puts "create comment for #{number}"
    ticket=cache.load(:name=>"fresnel_ticket_#{number}",:action=>"Lighthouse::Ticket.find(#{number}, :params => { :project_id => #{self.current_project_id} })")

    File.open("/tmp/fresnel_ticket_#{number}_comment", "w+") do |f|
      f.puts
      f.puts "# Please enter the comment for this ticket. Lines starting"
      f.puts "# with '#' will be ignored, and an empty message aborts the commit."
      `fresnel #{number}`.each{ |l| f.write "# #{l}" }
    end

    system("mate -w /tmp/fresnel_ticket_#{number}_comment")

    body=Array.new
    File.read("/tmp/fresnel_ticket_#{number}_comment").each do |l|
      body << l unless l=~/^#/
    end

    body=body.to_s
    if body.blank?
      puts Frame.new(:header=>"Warning !", :body=>"Aborting comment because it was blank !")
    else
      ticket.body=body
      if ticket.save
        cache.clear(:name=>"fresnel_ticket_#{number}")
        show_ticket(number)
      else
        puts "something went wrong"
        puts $!
      end
    end
  end

  def create
    system("mate -w /tmp/fresnel_new_ticket")
    data=File.read("/tmp/fresnel_new_ticket")
    body=Array.new
    title=""
    if data.blank?
      puts Frame.new(:header=>"Warning !", :body=>"Aborting creation because the ticket was blank !")
    else
      data.each do |l|
        if title.blank?
          title=l
          next
        end
        body << l
      end
      body=body.to_s
      tags=ask("Tags : ")
      tags=tags.split(" ")
    end
    ticket = Lighthouse::Ticket.new(
      :project_id=>self.current_project_id,
      :title=>title,
      :body=>body
    )
    ticket.tags=tags
    if ticket.save
      File.delete("/tmp/fresnel_new_ticket")
      show_ticket(ticket.number)
    else
      puts "something went wrong !"
      puts $!
    end
  end
end