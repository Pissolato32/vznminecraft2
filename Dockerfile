# Dockerfile otimizado

# JRE base (camada base, raramente muda, ideal para cache)
FROM eclipse-temurin:19-jre-jammy

# Variáveis de ambiente (definidas cedo, mudam com pouca frequência)
ENV SERVER_PROVIDER="purpur" \
    LAZYMC_VERSION="latest" \
    MC_VERSION="latest" \
    SERVER_BUILD="latest" \
    MC_RAM="" \
    JAVA_OPTS="" \
    # Adicionando uma variável para o diretório de trabalho padrão
    MCSERVER_DIR="/mcserver"

# Criar o diretório de trabalho e definir como WORKDIR (criação de diretórios estáveis)
RUN mkdir -p ${MCSERVER_DIR}
WORKDIR ${MCSERVER_DIR}

# Instalar dependências e limpar o cache (executado uma vez)
# Usamos `apt-get` ao invés de `apt` para maior compatibilidade em scripts
RUN apt-get update && \
    apt-get install -y --no-install-recommends wget jq curl && \
    rm -rf /var/lib/apt/lists/*

# Copiar o script principal (mudanças frequentes, camada separada)
# O '.' agora se refere ao WORKDIR (/mcserver)
COPY mcserver.sh .

# Configuração do contêiner
EXPOSE 25565/tcp
EXPOSE 25565/udp
EXPOSE 25575/tcp
EXPOSE 25575/udp
VOLUME ${MCSERVER_DIR}

# Comando de inicialização
CMD ["sh", "./mcserver.sh"]
