#----
# Set up preseeding data for debian packages
#---
directory '/var/cache/local/preseeding' do
  owner 'root'
  group 'root'
  mode '0755'
  recursive true
end

template '/var/cache/local/preseeding/mysql-server.seed' do
  source 'mysql-server.seed.erb'
  owner 'root'
  group 'root'
  mode '0600'
  notifies :run, 'execute[preseed mysql-server]', :immediately
end

execute 'preseed mysql-server' do
  command '/usr/bin/debconf-set-selections /var/cache/local/preseeding/mysql-server.seed'
  action  :nothing
end

#----
# Install software
#----
node['mysql']['server']['packages'].each do |name|
  package name do
    action :install
  end
end

# the original loop in the mysql cookbook set a lot of loose permissions
# instead lets match them up with how debian sets them by default
directory node['mysql']['server']['directories']['log_dir'] do
  owner     'mysql'
  group     'mysql'
  mode      '0700'
  action    :create
  recursive true
end
directory node['mysql']['server']['directories']['slow_log_dir'] do
  owner     'mysql'
  group     'adm'
  mode      '2750'
  action    :create
  recursive true
end
directory node['mysql']['server']['directories']['confd_dir'] do
  owner     'root'
  group     'root'
  mode      '755'
  action    :create
  recursive true
end

#----
# Grants
#----
template '/etc/mysql_grants.sql' do
  source 'grants.sql.erb'
  owner  'root'
  group  'root'
  mode   '0600'
  notifies :run, 'execute[install-grants]', :immediately
end

cmd = install_grants_cmd
execute 'install-grants' do
  command cmd
  action :nothing
end

# by this point we've changed the debian-sys-maint password, we need to update the template
template '/etc/mysql/debian.cnf' do
  source 'debian.cnf.erb'
  owner 'root'
  group 'root'
  mode '0600'
  notifies :reload, 'service[mysql]'
end

#----
# data_dir
#----

# DRAGONS!
# Setting up data_dir will only work on initial node converge...
# Data will NOT be moved around the filesystem when you change data_dir
# To do that, we'll need to stash the data_dir of the last chef-client
# run somewhere and read it. Implementing that will come in "The Future"

directory node['mysql']['data_dir'] do
  owner     'mysql'
  group     'mysql'
  action    :create
  recursive true
end

# debian package still has traditional init script
template '/etc/init/mysql.conf' do
  source 'init-mysql.conf.erb'
  only_if { node['platform_family'] == 'ubuntu' }
end

template '/etc/apparmor.d/usr.sbin.mysqld' do
  source 'usr.sbin.mysqld.erb'
  action :create
  notifies :reload, 'service[apparmor-mysql]', :immediately
end

service 'apparmor-mysql' do
  service_name 'apparmor'
  action :nothing
  supports :reload => true
end

template '/etc/mysql/my.cnf' do
  source 'my.cnf.erb'
  owner 'root'
  group 'root'
  mode '0644'
  notifies :run, 'bash[move mysql data to datadir]', :immediately
  notifies :reload, 'service[mysql]'
end

# don't try this at home
# http://ubuntuforums.org/showthread.php?t=804126
bash 'move mysql data to datadir' do
  user 'root'
  code <<-EOH
  /usr/sbin/service mysql stop &&
  mv /var/lib/mysql/* #{node['mysql']['data_dir']} &&
  /usr/sbin/service mysql start
  EOH
  action :nothing
  only_if "[ '/var/lib/mysql' != #{node['mysql']['data_dir']} ]"
  only_if "[ `stat -c %h #{node['mysql']['data_dir']}` -eq 2 ]"
  not_if '[ `stat -c %h /var/lib/mysql/` -eq 2 ]'
end

service 'mysql' do
  service_name 'mysql'
  supports     :status => true, :restart => true, :reload => true
  action       [:enable, :start]
end
