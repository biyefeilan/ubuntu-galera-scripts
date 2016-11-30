#!/bin/bash

read -p "Mysql cluster name[my_cluster]: " cluster_name
[ -z "$cluster_name" ] && cluster_name=my_cluster

read -p "Mysql cluster address: " cluster_addr
if [ -z "$cluster_addr" ]; then
    echo "Cluster address is required!"
    exit 1
fi

read -p "Mysql cluster node name: " node_name
if [ -z "$node_name" ]; then
    echo "Cluster node name is required!"
    exit 1
fi

read -p "Mysql cluster node address: " node_addr
if [ -z "$node_addr" ]; then
    echo "Cluster node adress is required!"
    exit 1
fi

read -p "Mysql cluster sst auth: " sst_auth

read -p "Mysql bind address[0.0.0.0]: " bind_addr
[ -z "$bind_addr" ] && bind_addr=0.0.0.0

first_node=true
while true; do
    read -p "Is this first node? (Y/n)" yn
    case $yn in
        [Nn]* ) first_node=false; break;;
        * ) break;;
    esac
done

apt-get install software-properties-common
apt-key adv --keyserver keyserver.ubuntu.com --recv BC19DDBA
str=`lsb_release -a 2>>/dev/null | awk -F ':' 'BEGIN {dist="ubuntu";release="trusty"} /^(Distributor|Codename)/{if($1 ~ /^Distributor/){dist=$2}else{release=$2}} END {gsub(/\s+/, "", release);gsub(/\s+/, "", dist);printf("%s %s", tolower(dist), tolower(release))}'`
echo -e "# Codership Repository (Galera Cluster for MySQL)\n\
deb http://releases.galeracluster.com/$str main" > /etc/apt/sources.list.d/galera.list
apt-get update
apt-get install -y galera-3 galera-arbitrator-3 mysql-wsrep-5.6
update-rc.d mysql defaults
myConf=/etc/mysql/my.cnf
sed -i '/^wsrep_\|^bind-address\b\|^binlog_format\b\|^default_storage_engine\b\|^innodb_autoinc_lock_mode\b\|^innodb_flush_log_at_trx_commit\b\|^innodb_buffer_pool_size\b/d' $myConf
sed -i '/^\[mysqld\]$/a binlog_format=ROW\nbind-address='$bind_addr'\ndefault_storage_engine=InnoDB\ninnodb_autoinc_lock_mode=2\ninnodb_flush_log_at_trx_commit=0\ninnodb_buffer_pool_size=2G\nwsrep_provider=/usr/lib/libgalera_smm.so\nwsrep_provider_options="gcache.size=300M; gcache.page_size=300M"\nwsrep_cluster_name="'$cluster_name'"\nwsrep_cluster_address="gcomm://'$cluster_addr'"\nwsrep_node_name="'$node_name'"\nwsrep_node_address="'$node_addr'"\nwsrep_sst_auth='$sst_auth'\nwsrep_sst_method=rsync' $myConf
[ -z "$sst_auth" ] && sed -i 's/^wsrep_sst_auth/#&/g' $myConf

if $first_node; then
    service mysql start --wsrep-new-cluster
    read -s -p "Input mysql root password: " mysql_root_pass
    mysql_user_host_tmp=`echo $node_addr | cut -d . -f 1-3`.%
    read -p "Input cluser mysql user host[$mysql_user_host_tmp]: " mysql_user_host
    if [ -z "$mysql_user_host" ]; then
        mysql_user_host=$mysql_user_host_tmp
    fi
    mysql -uroot -p${mysql_root_pass} <<EOF
drop database if exists test;
delete from mysql.user where not (user='root');
delete from mysql.db where user='';
create user 'haproxy'@'$mysql_user_host';
flush privileges;
exit
EOF
    if [ -n "$sst_auth" ]; then
        sst_auth=(${sst_auth//:/ })
        sst_auth_user=${sst_auth[0]}
        sst_auth_pass=${sst_auth[1]}
        mysql -uroot -p${mysql_root_pass} <<EOF
grant all privileges on *.* to '$sst_auth_user'@'$mysql_user_host' identified by '$sst_auth_pass';
flush privileges;
exit
EOF
    fi
else
    service mysql start
fi

cat > /etc/iptables.rules <<EOF
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -s 192.168.0.0/24 -i eth0 -p tcp -m tcp --dport 3306 -j ACCEPT
-A INPUT -s 192.168.0.0/24 -i eth0 -p tcp -m tcp --dport 4567 -j ACCEPT
-A INPUT -s 192.168.0.0/24 -i eth0 -p tcp -m tcp --dport 4568 -j ACCEPT
-A INPUT -s 192.168.0.0/24 -i eth0 -p tcp -m tcp --dport 4444 -j ACCEPT
-A INPUT -s 192.168.0.0/24 -i eth0 -p udp -m udp --dport 4567 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
COMMIT
EOF
iptables-restore < /etc/iptables.rules
cat > /etc/network/if-pre-up.d/iptablesload <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
exit 0
EOF
cat > /etc/network/if-post-down.d/iptablessave <<EOF
#!/bin/sh
iptables-save -c > /etc/iptables.rules
if [ -f /etc/iptables.downrules ]; then
   iptables-restore < /etc/iptables.downrules
fi
exit 0
EOF
chmod +x /etc/network/if-post-down.d/iptablessave
chmod +x /etc/network/if-pre-up.d/iptablesload

grep -q '^\*\s*soft\s*nofile' /etc/security/limits.conf
if [ $? -ne 0 ]; then
    sed -i '$i*     soft    nofile  65535' /etc/security/limits.conf
fi
grep -q '^\*\s*hard\s*nofile' /etc/security/limits.conf
if [ $? -ne 0 ]; then
    sed -i '$i*     hard    nofile  65535' /etc/security/limits.conf
fi
ulimit -SHn 65535

echo 30 > /proc/sys/net/ipv4/tcp_fin_timeout
echo 4096 > /proc/sys/net/ipv4/tcp_max_syn_backlog
echo 262144 > /proc/sys/net/ipv4/tcp_max_tw_buckets
echo 262144 > /proc/sys/net/ipv4/tcp_max_orphans
echo 1 > /proc/sys/net/ipv4/tcp_tw_recycle
echo 0 > /proc/sys/net/ipv4/tcp_timestamps
echo 0 > /proc/sys/net/ipv4/tcp_ecn
echo 1 > /proc/sys/net/ipv4/tcp_sack
echo 1 > /proc/sys/net/ipv4/tcp_tw_reuse
