#!/bin/bash

sudo -i <<'EOF'
echo "export DSS_USER=<DSS_USER>" > /data/dataiku/variable.sh
echo "export YOUR_DSS_USER=<YOUR_DSS_USER>" >> /data/dataiku/variable.sh
echo "export YOUR_USER_PASSWORD=<YOUR_USER_PASSWORD>" >> /data/dataiku/variable.sh
echo "export HIVESERVER2_HOST=<HIVESERVER2_HOST>" >> /data/dataiku/variable.sh
echo "export DSS_VERSION=<DSS_VERSION>" >> /data/dataiku/variable.sh
chmod 777 /data/dataiku/variable.sh
EOF


echo -----------------------------
echo Install automation node
echo -----------------------------

source /data/dataiku/variable.sh

sudo su - $DSS_USER <<'EOF'
source /data/dataiku/variable.sh
cd /data/dataiku
./dataiku-dss-$DSS_VERSION/installer.sh -t automation -d /data/dataiku/auto_dir -p 12000 -l /data/$DSS_USER/license.json
EOF

source /data/dataiku/variable.sh
sudo -i "/data/dataiku/dataiku-$DSS_VERSION/scripts/install/install-boot.sh" "/data/dataiku/auto_dir" $DSS_USER
sudo yum install -y jq

## Uncomment if you installed R integration and want to do so on the Automation Node as well
#echo -----------------------------
#echo Install R integration
#echo -----------------------------
#
#sudo su  $DSS_USER <<'EOF'
#source /data/dataiku/variable.sh
#cd /data/dataiku
#./auto_dir/bin/dssadmin install-R-integration
#EOF


echo -----------------------------
echo Install hadoop integration
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /data/dataiku/variable.sh
cd /data/dataiku
kdestroy
kinit -kt /data/$DSS_USER/$DSS_USER.keytab $DSS_USER@TRAINING.DATAIKU.COM
klist -e
./auto_dir/bin/dssadmin install-hadoop-integration -keytab /data/$DSS_USER/$DSS_USER.keytab -principal $DSS_USER@TRAINING.DATAIKU.COM
EOF


echo -----------------------------
echo Install Spark integration
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /data/dataiku/variable.sh
cd /data/dataiku
./auto_dir/bin/dssadmin install-spark-integration
EOF


echo -----------------------------
echo Install multiUserSecurity
echo -----------------------------
source /data/dataiku/variable.sh
sudo /data/dataiku/auto_dir/bin/dssadmin install-impersonation $DSS_USER


echo -----------------------------
echo Set up multiUserSecurity
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /data/dataiku/variable.sh
cd /data/dataiku
echo "export INSTALL_ID=$(cat ./auto_dir/install.ini | grep installid | awk -F' = ' '{print $2}')" >> /opt/dataiku/variable.sh
EOF

source /data/dataiku/variable.sh
sudo sed -i "s/allowed_user_groups =/allowed_user_groups = ${DSS_USER}-users/" /etc/dataiku-security/$INSTALL_ID/security-config.ini
sudo cat /etc/dataiku-security/$INSTALL_ID/security-config.ini

echo -----------------------------
echo Start automation node
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
cd /data/dataiku
./auto_dir/bin/dss start 
EOF

echo "sleeping 10s to allow DSS to start"
sleep 10
echo "awake!"

echo -----------------------------
echo Generate API Key
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /data/dataiku/variable.sh
cd /data/dataiku
AUTO_JSON=$(./auto_dir/bin/dsscli api-key-create --output json --admin true --description "admin key for automation node setup script" --label "auto_script_key")
echo "export AUTO_KEY=$(echo $AUTO_JSON | jq '.[] | .key')" >> /data/dataiku/variable.sh
source /data/dataiku/variable.sh
echo $AUTO_KEY
EOF

source /data/dataiku/variable.sh

echo -----------------------------
echo Create Sql connection
echo ----------------------------

source /data/dataiku/variable.sh
echo ' 
import requests
import json
import os 

HOST = "http://localhost:12000/public/api"
PATH="/admin/connections/"
API_KEY=os.environ["AUTO_KEY"]

DATA = {
    "params": {
        "host": "localhost",
        "user": "dataiku",
        "password": "dataiku",
        "db": "dataiku"
    },
    "name": "postgres_conn",
    "type": "PostgreSQL",
    "allowWrite": True,
    "allowManagedDatasets": True,
    "allowManagedFolders": True,
    "usableBy": "ALL"
    }

r = requests.post(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, data=json.dumps(DATA), verify=False)
print r.text' > /tmp/create_postgres_conn.py

python /tmp/create_postgres_conn.py


echo -----------------------------
echo Update HDFS connection
echo ----------------------------

source /data/dataiku/variable.sh
echo ' 
import requests
import json
import os 

HOST = "http://localhost:12000/public/api"
PATH="/admin/connections/hdfs_managed"
API_KEY=os.environ["AUTO_KEY"]

r = requests.get(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, verify=False)
hdfs_conn=json.loads(r.text)

hdfs_conn["params"]["aclSynchronizationMode"] = "NONE"
hdfs_conn["params"]["namingRule"] = {
    "hdfsPathDatasetNamePrefix": "${projectKey}/",
    "tableNameDatasetNamePrefix": "${projectKey}_",
    "hiveDatabaseName": "%s" %os.environ["DSS_USER"],
    "uploadsPathPrefix": "uploads"
}

r = requests.put(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, data=json.dumps(hdfs_conn), verify=False)
print r.text' > /tmp/update_hdfs_conn.py

python /tmp/update_hdfs_conn.py


echo -----------------------------
echo Configure DSS - Hadoop, Spark, and MUS
echo -----------------------------

source /data/dataiku/variable.sh
echo ' 
import requests
import json
import os 

HOST = "http://localhost:12000/public/api"
PATH="/admin/general-settings/"
API_KEY=os.environ["AUTO_KEY"]

r = requests.get(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, verify=False)
dss_settings=json.loads(r.text)


user_mapping ={
    "dssUser": os.environ["YOUR_DSS_USER"],
    "type": "SINGLE_MAPPING",
    "scope": "GLOBAL",
    "targetHadoop": "%s-user1" %os.environ["DSS_USER"],
    "targetUnix": "%s-user1" %os.environ["DSS_USER"]
}

group_mapping = {
    "targetHadoop": "%s-users" %os.environ["DSS_USER"],
    "targetUnix": "%s-users" %os.environ["DSS_USER"],
    "type": "SINGLE_MAPPING",
    "dssGroup": "biz_x_data_scientists"
}

default_spark_config = [
	{"name" : "default",
	 "description": " default configuration",
	 "conf": [{"key":"spark.master", "value": "yarn-client"}]
	}
]

hive_settings = {
    "enabled": True,
    "engineCreationSettings": {
        "executionEngine": "HIVESERVER2"
    },
    "hiveServer2Host": os.environ["HIVESERVER2_HOST"],
    "hiveServer2Port": 10000,
    "hiveServer2Principal": "hive/_HOST@TRAINING.DATAIKU.COM",
    "useURL": False
}

dss_settings["impersonation"]["userRules"].insert(0,user_mapping)
dss_settings["impersonation"]["groupRules"].insert(0,group_mapping)
dss_settings["hiveSettings"]=hive_settings
dss_settings["sparkSettings"]["executionConfigs"]=default_spark_config

r = requests.put(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, data=json.dumps(dss_settings), verify=False)
print r.text
print "Configuration Complete!"' > /tmp/modify_global_config.py

python /tmp/modify_global_config.py


echo -----------------------------
echo Create User and Group User and Group 
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /data/dataiku/variable.sh
cd /data/dataiku
./auto_dir/bin/dsscli group-create --description "Data Scientists from Business X" --source-type LOCAL --may-create-project true --may-write-unsafe-code true --may-write-safe-code true --may-create-code-envs true --may-develop-plugins true --may-create-published-api-services true biz_x_data_scientists
./auto_dir/bin/dsscli user-create --source-type LOCAL --display-name $YOUR_DSS_USER --user-profile DESIGNER --group biz_x_data_scientists $YOUR_DSS_USER $YOUR_USER_PASSWORD
echo "Finished with User and Group Creation!"
EOF

