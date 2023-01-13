#!/bin/bash +e
#TODO
#根据ansible添加变量
#ssh localhost + 其他节点
#wrsep_new_cluster command: mysqld --wsrep_new_cluster
ssh_user='root'
galera_state_file='/var/lib/mysql/grastate.dat'
galera_cluster_conf_file='/etc/mysql/conf.d/cluster.cnf'
cluster_is_running=false
safe_to_boot_node=''
boot_from_local=false
reachable_timeout=300
running_timeout=300 

###define functions###

#check port connection
function checkPort(){
#$1 host
#$2 port
#$3 timeout seconds
begin_time=`date +%s`
timeleap=0
rc=1

until [[ ${timeleap} -gt ${3} ]]
do
  #check mysql status
  if [[ $2 -eq 3306 ]]
  then
    ssh $ssh_user@$1 mysqladmin ping &>/dev/null && rc=0 && break 
  else
    nc -z $1 $2 2>&1 && rc=0 && break 
  fi
  sleep 1
  current_time=`date +%s`
  let timeleap=${current_time}-${begin_time}
done 

return $rc
}



#first node bootstrap
function galera_cluster_bootstrap(){
  recovered_position=`galera_recovery 2>&1 |tail -1 | awk -F':' '{print $2}'`
  sed -ie "/seqno/c\seqno: $recovered_position" $galera_state_file
  sed -ie "/safe_to/c\safe_to_bootstrap:\ 1" $galera_state_file
  galera_new_cluster
  #reset safe_to_boot flag if recover failed
  mysqladmin ping &>/dev/null
  if [ $? -ne 0 ]
  then
    echo -e "mysql bootstrap failed"
    sed -ie "/safe_to/c\safe_to_bootstrap:\ 0" $galera_state_file
  fi
}

###finish defining###
###start to go###

#check local mysql status
mysqladmin ping &> /dev/null
if [ $? -eq 0 ]
then
  echo -e "Local mysql is already running..\nQuit starting"
  exit 0
else
  echo "Local mysql is stopped, checking other node status.."
  #clean autostart process
  killall -9 mysqld
fi

if [ ! -f $galera_cluster_conf_file ]
then
  echo -e "config file $galera_cluster_conf_file doesn't exit!"
  exit 1
fi

cluster_string=`cat "$galera_cluster_conf_file" | grep wsrep_cluster_address | awk -F '//' '{print $2}' | awk -F '"' '{print $1}'`

IFS=',' read -r -a cluster_hosts <<< $cluster_string

#loop other nodes
#Quick Check
for host in ${cluster_hosts[*]}
do
  #quit loop when running node is found
  if $cluster_is_running
  then
    break
  fi
  
  #skip localhost
  if [[ `ifconfig | grep -c $host` -gt 0 ]] 
  then
    localip=$host
    continue
  fi
  
  #check reachable
  nc -z $host 22 2>&1
  if [ $? -ne 0 ]
  then
    echo -e "$host is unreachable!"
    continue
  else
    echo -e "$host is reachable"
  fi
  
  #check mysql port
  ssh $ssh_user@$host mysqladmin ping &> /dev/null
  if [ $? -eq 0  ]
  then
    echo -e "mysql in $host is running, start local mysql immediately"
    systemctl restart mysql
    exit 0 
  else
    echo -e "mysql in $host is not running"
  fi
done

#no mysql is running
#find safe_to_boot node
for host in ${cluster_hosts[*]}
do
  boot_var=`ssh $ssh_user@$host cat $galera_state_file | grep safe_to_bootstrap | awk -F': ' '{print $2}'`
  if [[ $boot_var -eq 1 ]]
  then
    safe_to_boot_node=$host
    if [[ `ifconfig | grep -c $host` -gt 0 ]]
    then 
      #bootstrap when localhost is safe_boot_node
      echo "bootstrap from localhost"
      galera_cluster_bootstrap
      exit 0
    fi
  fi
done

#other node is safe-boot-node
if [[ "$safe_to_boot_node" != '' ]]
then
  #wait for host to boot 
  echo -e "Safeboot host found : $safe_to_boot_node, waiting ${running_timeout}s for booting at that node.."
  checkPort $safe_to_boot_node 3306 $running_timeout
  if [ $? -eq 0  ]
  then
    systemctl restart mysql
  else
    echo "Timeout waiting ${running_timeout}s for safenode ${safe_to_boot_node} to boot"
    exit 1
  fi
#no safe node 
else
  echo "no safe_to_boot node, start comparing.."
  #check all node status, wait for unreachable host
  info_array=()
  for host in ${cluster_hosts[*]} 
  do 
    checkPort $host 22 $reachable_timeout
    if [ $? -ne 0 ]
    then
      echo -e "$host is unreachable when there is no safe_booted node"
      exit 1
    fi
    seqno=`ssh $ssh_user@$host galera_recovery 2>&1 |tail -1 | awk -F':' '{print $3}'`
    info=${host}":"${seqno}
    
    info_array+=($info)
  done
  
  #compare seqno when all nodes are reachable

  for info in ${info_array[*]}
  do
    host=`awk -F':' '{print $1}' <<< $info`
    seqno=`awk -F':' '{print $2}' <<< $info`
    lastip=`awk -F'.' '{print $4}' <<< $host`
    
    if [ ! -n "$safe_seqno" ] ;then safe_seqno=$seqno;fi
    if [ ! -n "$safe_host" ] ;then safe_host=$host;fi
    if [ ! -n "$safe_lastip" ] ;then safe_lastip=$lastip;fi

    if [[ $seqno -gt $safe_seqno ]]
    then 
      safe_seqno=$seqno
      safe_host=$host
      safe_lastip=$lastip
    elif [[ $seqno -eq $safe_seqno  ]] && [[ $lastip -lt $safe_lastip ]]
    then
      safe_seqno=$seqno
      safe_host=$host
      safe_lastip=$lastip
    else
      continue
    fi
  done
  
  if [[ `ifconfig | grep -c $safe_host` -gt 0 ]] 
  then
    echo "bootstrap from localhost"
    galera_cluster_bootstrap
  else
    #all nodes are up, wait for safe_to_boot node starting
    echo -e "Safeboot host found : $safe_host, Waiting ${running_timeout}s for booting at that node.."
    checkPort $safe_host 3306 $running_timeout
    if [ $? -eq 0  ]
    then
      systemctl restart mysql
    else
      echo -e "Timeout waiting ${running_timeout}s for safenode $safe_host to boot"
      exit 1
    fi
  fi
fi

