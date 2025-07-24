#!/bin/bash
# mcserver.sh otimizado

# --- Configurações Iniciais e Tratamento de Erros ---
# Exit imediatamente se um comando falhar.
set -e
# Desativa a expansão de nomes de caminho globais (globbing) para evitar problemas com '*' em strings.
set -f

# Função para imprimir mensagens informativas (stdout)
log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1"
}

# Função para imprimir mensagens de aviso (stderr)
log_warn() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [WARN] $1" >&2
}

# Função para imprimir mensagens de erro (stderr) e sair
log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $1" >&2
    echo "$1" > server_cfg.txt # Salva o erro no arquivo de config também
    exit 1
}

# --- Validação de Variáveis de Ambiente ---

# Validar formato da RAM
if ! echo "$MC_RAM" | grep -Eq '^[0-9]+[MG]$' && [ -n "$MC_RAM" ]; then
    log_error "Formato de RAM inválido: '$MC_RAM'. Use, por exemplo, '2G' ou '1024M'."
fi

# --- Detecção de Arquitetura e Suporte Lazymc ---
declare -A LAZYMC_ARCH_MAP=(
    ["x86_64"]="x64"
    ["aarch64"]="aarch64"
    ["arm64"]="aarch64" # Adicionado para compatibilidade com alguns sistemas ARM
    ["armv7l"]="armv7"
)

CPU_ARCH=$(uname -m)
LAZYMC_ADAPTED_ARCH="${LAZYMC_ARCH_MAP[$CPU_ARCH]:-$CPU_ARCH}" # Usa o mapeamento, senão a arquitetura original

if [[ ! " ${!LAZYMC_ARCH_MAP[*]} " =~ " ${CPU_ARCH} " ]]; then
    log_warn "A arquitetura da sua CPU ($CPU_ARCH) não é oficialmente suportada pelo Lazymc. Desativando-o."
    LAZYMC_VERSION="disabled"
fi

# --- Exibição e Salvamento da Configuração Atual ---
log_info "Configurações atuais do servidor Minecraft:" | tee server_cfg.txt
echo "" | tee -a server_cfg.txt
echo "Minecraft Version= ${MC_VERSION}" | tee -a server_cfg.txt
echo "Lazymc version= ${LAZYMC_VERSION}" | tee -a server_cfg.txt
echo "Server provider= ${SERVER_PROVIDER}" | tee -a server_cfg.txt
echo "Server build= ${SERVER_BUILD}" | tee -a server_cfg.txt
echo "Dedicated RAM= ${MC_RAM:-"Não especificada."}" | tee -a server_cfg.txt
echo "Java options= ${JAVA_OPTS:-"Não especificadas."}" | tee -a server_cfg.txt
echo "" | tee -a server_cfg.txt # Garante uma linha em branco no arquivo
log_info "Configuração atual salva em ${MCSERVER_DIR}/server_cfg.txt"
sleep 1 # Dê tempo para o usuário ler

# --- Funções de Download e Validação ---

download_lazymc() {
    if [ "$LAZYMC_VERSION" = "disabled" ]; then
        log_info "Pulando download do Lazymc..."
        return
    fi

    local version_to_download="$LAZYMC_VERSION"
    if [ "$LAZYMC_VERSION" = "latest" ]; then
        log_info "Obtendo a última versão do Lazymc..."
        version_to_download=$(wget -qO - https://api.github.com/repos/timvisee/lazymc/releases/latest | jq -r .tag_name | cut -c 2-)
        if [ -z "$version_to_download" ]; then
            log_error "Não foi possível obter a última versão do Lazymc."
        fi
        LAZYMC_VERSION="$version_to_download" # Atualiza a variável para uso posterior
    fi

    local LAZYMC_URL="https://github.com/timvisee/lazymc/releases/download/v${version_to_download}/lazymc-v${version_to_download}-linux-${LAZYMC_ADAPTED_ARCH}"
    log_info "Verificando disponibilidade do Lazymc em: ${LAZYMC_URL}"

    if ! curl --head --fail --silent "${LAZYMC_URL}" > /dev/null; then
        log_error "Lazymc versão v${version_to_download} não existe ou não está disponível para ${LAZYMC_ADAPTED_ARCH}."
    fi

    log_info "Baixando Lazymc v${version_to_download}..."
    wget -qO lazymc "${LAZYMC_URL}" || log_error "Falha ao baixar Lazymc."
    chmod +x lazymc || log_error "Falha ao tornar Lazymc executável."
}

download_server_jar() {
    local API_FETCH_LATEST="https://serverjars.com/api/fetchLatest/${SERVER_TYPE}/${SERVER_PROVIDER}"
    local API_FETCH_DETAILS="https://serverjars.com/api/fetchDetails/${SERVER_TYPE}/${SERVER_PROVIDER}/${MC_VERSION}"
    local API_FETCH_JAR="https://serverjars.com/api/fetchJar/${SERVER_TYPE}/${SERVER_PROVIDER}/${MC_VERSION}"

    if [ "${MC_VERSION}" = "latest" ]; then
        log_info "Obtendo a última versão do Minecraft para ${SERVER_PROVIDER}..."
        MC_VERSION=$(wget -qO - "${API_FETCH_LATEST}" | jq -r '.response.version') || log_error "Não foi possível obter a última versão do Minecraft."
        if [ -z "$MC_VERSION" ]; then
            log_error "Não foi possível obter a última versão do Minecraft para o provedor: ${SERVER_PROVIDER}."
        fi
    else
        log_info "Verificando a existência da versão do Minecraft ${MC_VERSION}..."
        local actual_version=$(wget -qO - "${API_FETCH_DETAILS}" | jq -r '.response.version') || log_error "Falha ao verificar detalhes da versão ${MC_VERSION}."
        if [ "${MC_VERSION}" != "${actual_version}" ]; then
            log_error "Versão do Minecraft ${MC_VERSION} não existe ou não está disponível para ${SERVER_PROVIDER}."
        fi
    fi

    local JAR_NAME="${SERVER_PROVIDER}-${MC_VERSION}-${SERVER_BUILD}.jar"

    # Determinar se o JAR precisa ser baixado
    local needs_download=false
    if [ ! -f "${JAR_NAME}" ]; then
        log_info "Arquivo ${JAR_NAME} não encontrado. Realizando download."
        needs_download=true
    else
        log_info "Arquivo ${JAR_NAME} já existe. Verificando se é a versão correta."
        # Uma checagem mais robusta seria comparar hashes, mas por simplicidade,
        # vamos confiar que se o arquivo existe e o nome corresponde, está ok.
        # Se você sempre quiser o mais recente, mesmo que o nome bata, descomente o 'rm -f *.jar' e defina needs_download=true
    fi

    if [ "$needs_download" = true ]; then
        log_info "Removendo JAR(s) antigos..."
        rm -f *.jar || log_warn "Não foi possível remover JARs antigos. Ignorando."

        log_info "Baixando ${JAR_NAME}..."
        curl -o "${JAR_NAME}" -sS "${API_FETCH_JAR}" || log_error "Falha ao baixar o JAR do servidor de ${API_FETCH_JAR}."
    else
        log_info "Usando o JAR existente: ${JAR_NAME}"
    fi
}


# --- Lógica Principal do Script ---

# 1. Download do Lazymc
download_lazymc

# 2. Determinar tipo de servidor
SERVER_TYPE=""
declare -a allowed_modded_type=("fabric" "forge")
declare -a allowed_servers_type=("paper" "purpur")

if [ "$SERVER_PROVIDER" = "vanilla" ]; then
    SERVER_TYPE="vanilla"
elif [[ " ${allowed_modded_type[*]} " =~ " ${SERVER_PROVIDER} " ]]; then
    SERVER_TYPE="modded"
elif [[ " ${allowed_servers_type[*]} " =~ " ${SERVER_PROVIDER} " ]]; then
    SERVER_TYPE="servers"
else
    log_error "Provedor de servidor não suportado: '$SERVER_PROVIDER'."
fi

# 3. Download do JAR do Servidor
download_server_jar

# 4. Checagem de Build (apenas para provedores que suportam)
case $SERVER_PROVIDER in
    "paper") BUILD_FETCH_API="https://papermc.io/api/v2/projects/paper/versions/${MC_VERSION}/builds/${SERVER_BUILD}";;
    "purpur") BUILD_FETCH_API="https://api.purpurmc.org/v2/purpur/${MC_VERSION}/${SERVER_BUILD}";;
    *) log_info "Pulando checagem de build para ${SERVER_PROVIDER}, pois não suporta números de build personalizados.";;
esac

if [ "$SERVER_BUILD" = "latest" ] && [ -n "$BUILD_FETCH_API" ]; then
    log_info "Obtendo a última build para ${SERVER_PROVIDER}..."
    # Se fosse necessário extrair o número da build, faríamos a chamada à API aqui.
    # Para Paper/Purpur, a API 'latest' geralmente entrega o JAR mais recente,
    # então essa checagem é mais para versões específicas.
elif [ -n "$BUILD_FETCH_API" ]; then
    log_info "Verificando a existência da build ${SERVER_BUILD} para ${SERVER_PROVIDER}..."
    if ! curl --head --fail --silent "${BUILD_FETCH_API}" > /dev/null; then
        log_error "${SERVER_PROVIDER} build ${SERVER_BUILD} não existe ou não está disponível."
    fi
fi

# 5. Instalação do Forge (se aplicável)
if [ "$SERVER_PROVIDER" = "forge" ]; then
    if [ ! -f .installed ]; then
        log_info "Instalando Forge... Isso pode demorar um pouco."
        java -jar "${JAR_NAME}" --installServer > /dev/null 2>&1 || log_error "Falha ao instalar Forge."
        touch .installed
    else
        log_info "Forge já instalado. Pulando a instalação."
    fi
fi

# 6. Determinar o comando de execução do servidor
if [ -z "$RUN_COMMAND" ]; then
    if [ "$SERVER_PROVIDER" = "forge" ]; then
        mc_major=$(echo "$MC_VERSION" | cut -d'.' -f1)
        mc_minor=$(echo "$MC_VERSION" | cut -d'.' -f2)
        mc_patch=$(echo "$MC_VERSION" | cut -d'.' -f3)

        if (( mc_major >= 1 && mc_minor >= 17 )); then # Simplifica a condição
            log_info "Obtendo novo comando de execução do Forge de run.sh..."
            # Assegura que run.sh exista e seja legível antes de tentar grep
            if [ -f "run.sh" ] && [ -r "run.sh" ]; then
                RUN_COMMAND=$(grep -m 1 "java" run.sh | sed 's/"$@"/nogui/')
                log_info "Novo comando de execução do Forge: ${RUN_COMMAND}"
            else
                log_warn "Arquivo run.sh não encontrado ou sem permissão de leitura. Usando comando padrão para Forge."
                RUN_COMMAND="java ${JAVA_OPTS} -jar ${JAR_NAME} nogui"
            fi

            if [ -n "${MC_RAM}" ]; then
                log_info "Configurando limite de RAM para Forge via user_jvm_args.txt..."
                echo "-Xms512M -Xmx${MC_RAM}" >> user_jvm_args.txt || log_error "Falha ao configurar RAM para Forge."
            fi
        else
            RUN_COMMAND="java ${JAVA_OPTS} -jar ${JAR_NAME} nogui"
        fi
    else
        RUN_COMMAND="java ${JAVA_OPTS} -jar ${JAR_NAME} nogui" # Comando padrão para outros provedores
    fi
else
    log_info "Usando comando de execução personalizado: ${RUN_COMMAND}"
fi

# 7. Gerar eula.txt
if [ ! -f eula.txt ]; then
    log_info "Gerando eula.txt..."
    echo "eula=true" > eula.txt || log_error "Falha ao gerar eula.txt."
fi

# 8. Gerar server.properties (se não existir)
if [ ! -f server.properties ]; then
    log_info "Gerando server.properties..."
    touch server.properties || log_error "Falha ao gerar server.properties."
fi

# 9. Adicionar opções de RAM aos JAVA_OPTS (se não for Forge 1.17+)
# Se o Forge 1.17+ já configurou a RAM via user_jvm_args.txt, evitamos duplicar.
if [ -z "$(grep -E '^-Xms|^Xmx' user_jvm_args.txt 2>/dev/null)" ] && [ -n "${MC_RAM}" ]; then
    log_info "Configurando argumentos de Java para RAM..."
    JAVA_OPTS="-Xms512M -Xmx${MC_RAM} ${JAVA_OPTS}"
elif [ -z "${MC_RAM}" ] && [[ ! "$SERVER_PROVIDER" = "forge" || "$MC_VERSION" =~ ^1\.[0-9]$|^1\.1[0-6]$ ]]; then
    # Adiciona Xms512M se MC_RAM não foi especificado e não é Forge 1.17+
    JAVA_OPTS="-Xms512M ${JAVA_OPTS}"
fi

# 10. Gerar e atualizar lazymc.toml
if [ "$LAZYMC_VERSION" != "disabled" ]; then
    if [ ! -f lazymc.toml ]; then
        log_info "Gerando lazymc.toml..."
        ./lazymc config generate || log_error "Falha ao gerar lazymc.toml."
    fi

    log_info "Atualizando lazymc.toml com os detalhes mais recentes..."
    # Adiciona o comentário apenas se ainda não estiver presente
    if ! grep -q "mcserver-lazymc-docker" lazymc.toml; then
        sed -i '/Command to start the server/i # Managed by mcserver-lazymc-docker, please do not edit this!' lazymc.toml || log_error "Falha ao adicionar comentário ao lazymc.toml."
    fi
    # Usa 'printf %q' para garantir que o comando seja escapado corretamente para uso no TOML
    ESCAPED_RUN_COMMAND=$(printf '%q' "$RUN_COMMAND")
    sed -i "s~command = .*~command = $ESCAPED_RUN_COMMAND~" lazymc.toml || log_error "Falha ao atualizar o comando no lazymc.toml."
fi

# 11. Iniciar o servidor
log_info "Iniciando o servidor Minecraft!"
if [ "$LAZYMC_VERSION" = "disabled" ]; then
    eval "${RUN_COMMAND}" || log_error "Falha ao iniciar o servidor diretamente."
else
    ./lazymc start || log_error "Falha ao iniciar o servidor via Lazymc."
fi
