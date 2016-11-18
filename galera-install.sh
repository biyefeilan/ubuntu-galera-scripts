#!/bin/sh
bind_addr=0.0.0.0
cluster_name=my_cluster
cluster_addr=node1,node2,node3

apt-get install software-properties-common
apt-key adv --keyserver keyserver.ubuntu.com --recv BC19DDBA
str=`lsb_release -a 2>>/dev/null | awk -F ':' 'BEGIN {dist="ubuntu";release="trusty"} /^(Distributor|Codename)/{if($1 ~ /^Distributor/){dist=$2}else{release=$2}} END {gsub(/\s+/, "", release);gsub(/\s+/, "", dist);printf("%s %s", tolower(dist), tolower(release))}'`
echo "# Codership Repository (Galera Cluster for MySQL)\n\
deb http://releases.galeracluster.com/$str main" > /etc/apt/sources.list.d/galera.list
apt-get update
apt-get install -y galera-3 galera-arbitrator-3 mysql-wsrep-5.6
update-rc.d mysql defaults
myConf=/etc/mysql/my.cnf
sed -i 's/^bind-address/#&/g' $myConf
sed -i '/^wsrep_\|^binlog_format\b\|^default_storage_engine\b\|^innodb_autoinc_lock_mode\b\|^innodb_flush_log_at_trx_commit\b\|^innodb_buffer_pool_size\b/d' $myConf
sed -i '/^\[mysqld\]$/a binlog_format=ROW\nbind-address='$bind_addr'\ndefault_storage_engine=InnoDB\ninnodb_autoinc_lock_mode=2\ninnodb_flush_log_at_trx_commit=0\ninnodb_buffer_pool_size=122M\nwsrep_provider=/usr/lib/libgalera_smm.so\nwsrep_provider_options="gcache.size=300M; gcache.page_size=300M"\nwsrep_cluster_name="'$cluster_name'"\nwsrep_cluster_address="gcomm://'$cluster_addr'"\nwsrep_sst_method=rsync' $myConf
service mysql restart
