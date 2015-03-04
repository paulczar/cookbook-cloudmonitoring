include_recipe 'xml::ruby'

chef_gem "fog" do
  version ">= #{node['cloud_monitoring']['fog_version']}"
  action :install
end

include_recipe 'cloud_monitoring::agent_repo'

# Get the agent id
if node['cloud_monitoring']['agent']['id'].nil?
  node['cloud_monitoring']['agent']['id'] = `xenstore-read name | head -n1 | sed "s/^instance-//"`
end

# Try to retireve agent token from the data bag
begin
  databag_dir = node["cloud_monitoring"]["credentials"]["databag_name"]
  databag_filename = node["cloud_monitoring"]["credentials"]["databag_item"]

  values = Chef::EncryptedDataBagItem.load(databag_dir, databag_filename)

  node.set['cloud_monitoring']['agent']['token'] = values['agent_token'] if values.to_hash.has_key? 'agent_token'
rescue Exception => e
  Chef::Log.error 'Failed to load rackspace cloud data bag: ' + e.to_s
end

if node['cloud_monitoring']['agent']['token'].nil?
  retrieve_agent_token
end

cloud_monitoring_agent_token node['cloud_monitoring']['agent']['id'] do
  rackspace_username  node['cloud_monitoring']['rackspace_username']
  rackspace_api_key   node['cloud_monitoring']['rackspace_api_key']
  action :create
end

package "rackspace-monitoring-agent" do
  if node['cloud_monitoring']['agent']['version'] == 'latest'
    action :upgrade
  else
    version node['cloud_monitoring']['agent']['version']
    action :install
  end

  notifies :restart, "service[rackspace-monitoring-agent]"
end

service "rackspace-monitoring-agent" do
  # TODO: RHEL, CentOS, ... support
  supports value_for_platform(
    "ubuntu" => { "default" => [ :start, :stop, :restart, :status ] },
    "default" => { "default" => [ :start, :stop ] }
  )

  case node[:platform]
    when "ubuntu"
    if node[:platform_version].to_f >= 9.10
      provider Chef::Provider::Service::Upstart
    end
  end

  action [ :enable, :start ]
end

template "/etc/rackspace-monitoring-agent.cfg" do
  source "rackspace-monitoring-agent.erb"
  owner "root"
  group "root"
  mode 0600
  variables lazy {
    {
      :monitoring_id => node['cloud_monitoring']['agent']['id'],
      :monitoring_token => node['cloud_monitoring']['agent']['token'],
    }
  }
  notifies :restart, "service[rackspace-monitoring-agent]", :delayed
end

node['cloud_monitoring']['plugins'].each_pair do |source_cookbook, path|
  remote_directory "cloud_monitoring_plugins_#{source_cookbook}" do
    path node['cloud_monitoring']['plugin_path']
    cookbook source_cookbook
    source path
    files_mode 0755
    owner 'root'
    group 'root'
    mode 0755
    recursive true
    purge false
  end
end

