# =============================================================================
# Makefile — Atalhos para comandos comuns
# =============================================================================
#
# CONCEITO: Makefile centraliza comandos longos em atalhos curtos.
# Ao invés de digitar "docker compose up -d --build", basta "make up".
# =============================================================================

.PHONY: up down build test logs provision clean

## Subir todos os containers
up:
	docker compose up -d --build

## Derrubar todos os containers
down:
	docker compose down

## Rebuild da imagem Go
build:
	docker compose build --no-cache

## Testar o endpoint principal
test:
	@echo "=== Endpoint /projeto-korp ==="
	@curl -s http://localhost:80/projeto-korp | python3 -m json.tool
	@echo "\n=== Health Check ==="
	@curl -s http://localhost:80/health | python3 -m json.tool
	@echo "\n=== Prometheus Target ==="
	@curl -s http://localhost:9090/api/v1/targets | python3 -c "import sys,json; data=json.load(sys.stdin); [print(f'  {t[\"labels\"][\"job\"]}: {t[\"health\"]}') for t in data['data']['activeTargets']]"

## Ver logs de todos os containers
logs:
	docker compose logs -f

## Provisionar tudo com Ansible (um comando)
provision:
	ansible-playbook -i ansible/inventory/hosts.yml ansible/playbook.yml

## Gerar tráfego para popular métricas
traffic:
	@echo "Gerando 100 requests..."
	@for i in $$(seq 1 100); do curl -s http://localhost/projeto-korp > /dev/null; done
	@echo "Pronto! Verifique o Grafana em http://localhost:3001"

## Limpar tudo (containers + imagens + redes)
clean:
	docker compose down --rmi all --volumes --remove-orphans
