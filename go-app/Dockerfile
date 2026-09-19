# =============================================================================
# Dockerfile — http-server-projeto-korp
# =============================================================================
#
# CONCEITO: Este arquivo é a "receita" para criar a imagem Docker.
# Docker lê linha a linha e executa cada instrução.
#
# Usamos MULTI-STAGE BUILD (construção em 2 etapas):
#   Etapa 1 (builder): Instala o Go, compila o código → gera o binário
#   Etapa 2 (runtime): Pega APENAS o binário e roda numa imagem mínima
#
# Resultado: imagem final de ~15MB ao invés de ~800MB
# =============================================================================


# =============================================================================
# ETAPA 1: BUILD (a "cozinha" onde preparamos o prato)
# =============================================================================
#
# "FROM golang:1.23-alpine AS builder"
#   - golang:1.23-alpine = imagem oficial do Go baseada em Alpine Linux (~300MB)
#   - Alpine é uma versão MINIMALISTA do Linux (muito menor que Ubuntu/Debian)
#   - AS builder = damos um NOME para esta etapa ("builder") para referenciá-la depois
#
# TRADEOFF: Por que Alpine e não a imagem golang padrão (~800MB)?
#   Alpine é menor e mais rápida de baixar. A desvantagem é que usa musl
#   ao invés de glibc, mas como compilamos com CGO_ENABLED=0, não importa.
# =============================================================================

FROM golang:1.25-alpine AS builder

# "WORKDIR /app" = cria a pasta /app e entra nela (como "cd /app")
# Todas as instruções seguintes acontecem dentro de /app
WORKDIR /app

# -------------------------------------------------------------------------
# Copiar go.mod PRIMEIRO (antes do código fonte)
#
# CONCEITO: Docker cria "layers" (camadas). Cada instrução COPY ou RUN
# cria uma camada. Se uma camada não mudou desde o último build,
# Docker reutiliza o cache (não executa de novo).
#
# Se copiarmos go.mod sozinho primeiro:
#   - Se APENAS o código (.go) mudou, Docker reutiliza o cache do go.mod
#   - O "go mod download" NÃO roda de novo (economiza tempo)
#   - Só recompila o código fonte
#
# Se copiássemos tudo junto (COPY . .):
#   - Qualquer mudança (até um comentário) invalidaria o cache
#   - Go mod download rodaria TODA VEZ (~30-60 segundos perdidos)
# -------------------------------------------------------------------------

COPY go.mod ./

# Copiar go.sum se existir (pode não existir se Go não está instalado no host)
COPY go.su[m] ./

# Copiar código fonte e gerar go.sum automaticamente
# CONCEITO: "go mod tidy" analisa os imports do código, baixa as
# dependências necessárias e gera o go.sum (arquivo de checksums).
# Isso é necessário porque não temos Go instalado no PC host.
COPY . .
RUN go mod tidy

# -------------------------------------------------------------------------
# Compilar o programa Go
#
# CGO_ENABLED=0 = desabilita o C Go (ligação com bibliotecas C)
#   → Gera um binário 100% estático (não depende de nada do sistema)
#   → ESSENCIAL para rodar em Alpine/scratch (que não tem glibc)
#
# GOOS=linux = compila para Linux (mesmo se estivéssemos buildando no Mac/Windows)
#
# -ldflags="-s -w" = remove informações de debug do binário
#   -s = remove tabela de símbolos (nomes de funções internas)
#   -w = remove informações de debug DWARF
#   → Reduz o tamanho do binário em ~30%
#   → Em produção não precisamos de debug symbols
#
# -o /http-server-projeto-korp = nome e local do binário gerado
# -------------------------------------------------------------------------

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /http-server-projeto-korp .


# =============================================================================
# ETAPA 2: RUNTIME (a "marmita" — só o prato pronto)
# =============================================================================
#
# "FROM alpine:3.20"
#   - Imagem limpa do Alpine Linux (~7MB)
#   - NÃO tem o compilador Go, NÃO tem o código fonte
#   - Tem apenas o sistema operacional mínimo
#
# TRADEOFF: Alpine (~7MB) vs scratch (0MB)?
#   - scratch: literalmente vazio, binário de ~10MB total
#     → Pro: menor imagem possível, menor superfície de ataque
#     → Contra: sem shell (não dá para entrar no container e debugar),
#       sem ferramentas (wget, curl), sem certificados TLS
#   - Alpine: shell + tools básicos, certificados TLS incluídos
#     → Pro: permite debug em produção, suporta HTTPS nativo
#     → Contra: ~7MB maior, tem mais programas (mais superfície)
#
#   DECISÃO: Alpine — o custo de 7MB é desprezível e o benefício de poder
#   debugar em produção é enorme quando algo dá errado às 3 da manhã.
# =============================================================================

FROM alpine:3.20

# -------------------------------------------------------------------------
# Criar usuário não-root
#
# CONCEITO: Por padrão, tudo no Docker roda como "root" (super-usuário).
# Isso é perigoso: se um atacante explorar uma falha na aplicação,
# ele tem acesso TOTAL ao container (e possivelmente ao host).
#
# Criamos um usuário "appuser" com privilégios limitados:
#   addgroup -S = cria grupo de sistema (sem senha, sem home)
#   adduser -S -G = cria usuário de sistema, no grupo especificado
#
# Referência: arquitetura_seguranca.md seção 3
#   "NUNCA rode a aplicação como usuário root no Dockerfile"
# -------------------------------------------------------------------------

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Copia APENAS o binário compilado da etapa "builder"
# CONCEITO: "--from=builder" diz "pega do estágio anterior chamado builder"
# Tudo que ficou no builder (compilador, código fonte, cache) é descartado
COPY --from=builder /http-server-projeto-korp /usr/local/bin/http-server-projeto-korp

# A partir daqui, tudo roda como "appuser" (não mais como root)
USER appuser

# Documenta qual porta o container usa (informativo, não abre a porta)
EXPOSE 8080

# -------------------------------------------------------------------------
# ENTRYPOINT: o comando que roda quando o container inicia
#
# CONCEITO: Diferença entre ENTRYPOINT e CMD:
#   - ENTRYPOINT: o programa principal (fixo, não é sobrescrito facilmente)
#   - CMD: argumentos padrão (podem ser sobrescritos pelo usuário)
#
# Usamos ENTRYPOINT porque nosso container tem UM propósito:
# rodar o servidor. Não faz sentido substituí-lo.
# -------------------------------------------------------------------------

ENTRYPOINT ["/usr/local/bin/http-server-projeto-korp"]
