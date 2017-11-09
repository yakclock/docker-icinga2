
MYSQL_HOST=${MYSQL_HOST:-""}
MYSQL_PORT=${MYSQL_PORT:-"3306"}

MYSQL_ROOT_USER=${MYSQL_ROOT_USER:-"root"}
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS:-""}
MYSQL_OPTS=

IDO_DATABASE_NAME=${IDO_DATABASE_NAME:-"icinga2core"}

if [ -z ${MYSQL_HOST} ]
then
  echo " [i] no MYSQL_HOST set ..."

  return
else

  if [ -z ${IDO_PASSWORD} ]
  then
    IDO_PASSWORD=$(pwgen -s 15 1)

    echo " [W] NO IDO PASSWORD SET!"
    echo " [W] DATABASE CONNECTIONS ARE NOT RESTART FIXED"
    echo " [W] I CREATE THIS PASSWORD DYNAMIC: '${IDO_PASSWORD}'"
  fi

  MYSQL_OPTS="--host=${MYSQL_HOST} --user=${MYSQL_ROOT_USER} --password=${MYSQL_ROOT_PASS} --port=${MYSQL_PORT}"
fi

# Version compare function
# 'stolen' from https://github.com/psi-4ward/docker-icinga2/blob/master/rootfs/init/mysql_setup.sh
# but modifyed for /bin/sh support
version_compare () {

  if [[ ${1} == ${2} ]]
  then
    echo '='
    return 0
  fi

  left="$(echo ${1} | sed 's/\.//g')"
  right="$(echo ${2} | sed 's/\.//g')"

  if [ ${left} -gt ${right} ]
  then
    echo ">"
    return 0
  elif [ ${left} -lt ${right} ]
  then
    echo "<"
    return 0
  else
    echo "="
    return 0
  fi

}

# create IDO database schema
#
create_schema() {

  enable_icinga_feature ido-mysql

  # check if database already created ...
  #
  query="SELECT TABLE_SCHEMA FROM information_schema.tables WHERE table_schema = \"${IDO_DATABASE_NAME}\" limit 1;"

  status=$(mysql ${MYSQL_OPTS} --batch --execute="${query}")

  if [ $(echo "${status}" | wc -w) -eq 0 ]
  then
    # Database isn't created
    # well, i do my job ...
    #
    echo " [i] initializing databases and icinga2 configurations"

    (
      echo "--- create user '${IDO_DATABASE_NAME}'@'%' IDENTIFIED BY '${IDO_PASSWORD}';"
      echo "CREATE DATABASE IF NOT EXISTS ${IDO_DATABASE_NAME};"
      echo "GRANT SELECT, INSERT, UPDATE, DELETE, DROP, CREATE VIEW, INDEX, EXECUTE ON ${IDO_DATABASE_NAME}.* TO 'icinga2'@'%' IDENTIFIED BY '${IDO_PASSWORD}';"
      echo "GRANT SELECT, INSERT, UPDATE, DELETE, DROP, CREATE VIEW, INDEX, EXECUTE ON ${IDO_DATABASE_NAME}.* TO 'icinga2'@'$(hostname -i)' IDENTIFIED BY '${IDO_PASSWORD}';"
      echo "GRANT SELECT, INSERT, UPDATE, DELETE, DROP, CREATE VIEW, INDEX, EXECUTE ON ${IDO_DATABASE_NAME}.* TO 'icinga2'@'$(hostname -s)' IDENTIFIED BY '${IDO_PASSWORD}';"
      echo "GRANT SELECT, INSERT, UPDATE, DELETE, DROP, CREATE VIEW, INDEX, EXECUTE ON ${IDO_DATABASE_NAME}.* TO 'icinga2'@'$(hostname -f)' IDENTIFIED BY '${IDO_PASSWORD}';"
      echo "FLUSH PRIVILEGES;"
    ) | mysql ${MYSQL_OPTS}

    if [ $? -eq 1 ]
    then
      echo " [E] can't create database '${IDO_DATABASE_NAME}'"
      exit 1
    fi

    insert_schema
  fi
}

# insert database structure
#
insert_schema() {

  # create the ido schema
  #
  mysql ${MYSQL_OPTS} --force ${IDO_DATABASE_NAME}  < /usr/share/icinga2-ido-mysql/schema/mysql.sql

  if [ $? -gt 0 ]
  then
    echo " [E] can't insert the icinga2 database schema"
    exit 1
  fi
}

# update database schema
#
update_schema() {

  # Database already created
  #
  # check database version
  # and install the update, when it needed
  #
  query="select version from ${IDO_DATABASE_NAME}.icinga_dbversion"
  db_version=$(mysql ${MYSQL_OPTS} --batch --execute="${query}" | tail -n1)

  if [ -z "${db_version}" ]
  then
    echo " [w] no database version found. skip database upgrade"

    insert_schema
    update_schema
  else

    echo " [i] database version: ${db_version}"

    for DB_UPDATE_FILE in $(ls -1 /usr/share/icinga2-ido-mysql/schema/upgrade/*.sql)
    do
      FILE_VER=$(grep icinga_dbversion ${DB_UPDATE_FILE} | grep idoutils | cut -d ',' -f 5 | sed -e "s| ||g" -e "s|\\'||g")

      if [ "$(version_compare ${db_version} ${FILE_VER})" = "<" ]
      then
        echo " [i] apply database update '${FILE_VER}' from '${DB_UPDATE_FILE}'"

        mysql ${MYSQL_OPTS} --force ${IDO_DATABASE_NAME}  < /usr/share/icinga2-ido-mysql/schema/upgrade/${DB_UPDATE_FILE}

        if [ $? -gt 0 ]
        then
          echo " [E] database update ${DB_UPDATE_FILE} failed"
          exit 1
        fi

      fi
    done

  fi
}

# update database configuration
#
create_config() {

  # create the IDO configuration
  #
  sed -i \
    -e 's|//host \= \".*\"|host \=\ \"'${MYSQL_HOST}'\"|g' \
    -e 's|//port \= \".*\"|port \=\ \"'${MYSQL_PORT}'\"|g' \
    -e 's|//password \= \".*\"|password \= \"'${IDO_PASSWORD}'\"|g' \
    -e 's|//user =\ \".*\"|user =\ \"icinga2\"|g' \
    -e 's|//database =\ \".*\"|database =\ \"'${IDO_DATABASE_NAME}'\"|g' \
    /etc/icinga2/features-available/ido-mysql.conf

}

. /init/wait_for/mysql.sh

create_schema
update_schema
create_config

# EOF
