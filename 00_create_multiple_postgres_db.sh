#!/bin/bash

set -e
set -u

# Espere para ter certeza de que o PostgreSQL ficou Up.
#echo "⏳ Aguardando disponibidedade do SGBD"
#sleep 45s

cmd="$@"
timer="5"

until runuser -l postgresql -c 'pg_isready' 2>/dev/null; do
  >&2 echo "PostgreSQL não está disponível, aguardando $timer seconds"
  sleep $timer
done

>&2 echo "Postgres is up - executing command"

echo " ⏳ Configurando o PostgreSQL"

# Connection options:
#   -h, --host=HOSTNAME      host do servidor de banco de dados
#   -p, --port=PORT          porta do servidor de banco de dados
#   -U, --username=USERNAME  nome de usuário do banco de dados
#   -w, --no-password        nunca solicitar senha
#   -W, --password           forçar prompt de senha (should happen automatically)

# databases
function create_user_and_database() {
  local database=$1
  echo " ⏳ Criando usuário e banco de dados '$database'"
  psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=postgres user=$POSTGRESQL_SUPERADMIN_USER" -W "$POSTGRESQL_SUPERADMIN_PASSWORD" <<-EOSQL

      --CREATE USER IF NOT EXISTS $POSTGRESQL_USERNAME WITH PASSWORD $POSTGRESQL_PASSWORD;
      ALTER USER $POSTGRESQL_USERNAME WITH CREATEDB CREATEROLE REPLICATION SUPERUSER;
      CREATE DATABASE $database;
      GRANT ALL PRIVILEGES ON DATABASE $database TO $POSTGRESQL_USERNAME;
EOSQL
}

# schemas
function create_schemas() {
  local database=$1
  echo " ⏳ Criando schemas para o banco de dados '$database'"
  # psql -v ON_ERROR_STOP=1 --username "$POSTGRESQL_USERNAME" --password "$POSTGRESQL_PASSWORD" -d "$database" <<-EOSQL
    psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" <<-EOSQL

        CREATE SCHEMA IF NOT EXISTS dbo;
        CREATE SCHEMA IF NOT EXISTS "ProgramaGestao";
        GRANT ALL ON SCHEMA dbo TO $POSTGRESQL_USERNAME;
        GRANT ALL ON SCHEMA "ProgramaGestao" TO $POSTGRESQL_USERNAME;
        SET search_path TO dbo;
        SET search_path TO "ProgramaGestao";
        ALTER DATABASE $database SET search_path TO dbo;
        ALTER DATABASE $database SET search_path TO "ProgramaGestao";

EOSQL
}

# migrations
function create_migrations() {
  local database=$1
  echo " ⏳ Excluindo schema padrão."
  # psql -v ON_ERROR_STOP=1 --username "$POSTGRESQL_USERNAME" --password "$POSTGRESQL_PASSWORD" -d "$database" <<-EOSQL
    psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" <<-EOSQL

        DROP SCHEMA IF EXISTS public CASCADE;
EOSQL

    echo " ⏳ Criando tabelas no '$database'"

    #################################################################################################
    #  Scripts necessários para criação da estrutura inicial do database.                           #
    #################################################################################################
    ## I. Criação da estrutura do banco de dados - Obrigatorio
    psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" -a -q -f "/usr/local/pgd-sqls/a_criacao_estrutura_bd_obrigatorio.sql"

    ## II. Inserir dados de domínio - Obrigatorio
    psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" -a -q -f "/usr/local/pgd-sqls/b_inserir_dados_dominio_obrigatorio.sql"

    ## III. Criação da tabela pessoa alocacao temporaria - Obrigatorio
    psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" -a -q -f "/usr/local/pgd-sqls/c_criacao_tabela_pessoa_alocacao_temp_obrigatorio.sql"

    ## IV. Alteracoes da estrutura do BD para a V7 - Correção de bugs
    psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" -a -q -f "/usr/local/pgd-sqls/d_alteracoes_estrutura_bd_para_v7.sql"

    ## V. Inserir dados de teste - Opcional ) (não necessário para produção)
    #psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" -a -q -f "/usr/local/pgd-sqls/e_inserir_dados_teste_opcional.sql"

    ## VI. Funcoes PostgreSQL - Obrigatorio
    psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" -a -q -f "/usr/local/pgd-sqls/f_funcoes_postgresql_obrigatorio.sql"

    #################################################################################################
    #  Scripts necessários para a instalação da API de envio dos dados de PGD para o órgão central. #
    #################################################################################################
    ## 1. Update Script 1 - Sob Demanda
    #psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" -a -q -f "/usr/local/pgd-sqls/script1_create_tables_sql_server_susep.sql"

    ## 2. Update Script 2 - Sob Demanda (versoes anteriores v1.7)
    ## psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" -a -q -f "/usr/local/pgd-sqls/script2_vews_api_pgd_susep_versoes_anteriores_v7.sql"

    ## 3. Update Script 2 - Sob Demanda (versoes v1.7+)
    #psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" -a -q -f "/usr/local/pgd-sqls/script2_views_api_pgd_susep.sql"

    ## Script extras - Sob Demanda (para listar pessoas versoes update v1.7+)
    psql -v ON_ERROR_STOP=1 -d "host=localhost port=5432 dbname=$database user=$POSTGRESQL_USERNAME" -W "$POSTGRESQL_PASSWORD" -a -q -f /usr/local/pgd-sqls/z_script_comandos_sobdemanda.sql
}

if [ "$( psql -XtAc "SELECT 1 FROM pg_database WHERE datname='pgd_staging'" )" = '1' ]
then
    echo " ⏳ Banco de dados existente."
else
    if [ -n "$POSTGRES_MULTIPLE_DATABASES" ]; then
        for db in $(echo $POSTGRES_MULTIPLE_DATABASES | tr ',' ' '); do
            create_user_and_database $db
        done
    fi

    if [ -n "$POSTGRES_MULTIPLE_DATABASES" ]; then
        for db in $(echo $POSTGRES_MULTIPLE_DATABASES | tr ',' ' '); do
            create_schemas $db
        done
    fi

    if [ -n "$POSTGRES_MULTIPLE_DATABASES" ]; then
        for db in $(echo $POSTGRES_MULTIPLE_DATABASES | tr ',' ' '); do
            create_migrations $db
        done
    fi
fi
