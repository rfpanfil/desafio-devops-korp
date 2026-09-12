#!/bin/bash
# audit.sh - Automated Security Audit Gate for CI/CD and Pre-commit
# Agnostic script: works in any FastAPI + React project structure.

set -euo pipefail
IFS=$'\n\t'

echo "🔍 Iniciando auditoria de segurança..."
EXIT_CODE=0

fail() {
    echo -e "🚨 FALHA: $1"
    EXIT_CODE=1
}

warn() {
    echo -e "⚠️ AVISO: $1"
}

ENGINE="native"

# Check for arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --engine) 
            [[ $# -ge 2 ]] || { echo "❌ --engine requer valor"; exit 1; }
            case "$2" in 
                native|snyk|semgrep) ENGINE="$2"; shift ;; 
                *) echo "❌ Parâmetro inválido para --engine. Use: native, snyk ou semgrep."; exit 1 ;; 
            esac
            ;;
        *) echo "Parâmetro desconhecido: $1"; exit 1 ;;
    esac
    shift
done

echo "🛡️ Engine selecionada: $ENGINE"
echo "----------------------------------------"

if [ "$ENGINE" == "snyk" ]; then
    echo "[1/3] Executando Snyk Open Source (SCA)..."
    if command -v snyk &> /dev/null; then
        snyk test || fail "Vulnerabilidades de dependências encontradas no Snyk!"
        echo "[2/3] Executando Snyk Code (SAST)..."
        snyk code test || fail "Vulnerabilidades no código encontradas pelo Snyk!"
    else
        fail "Snyk CLI não encontrado."
    fi

elif [ "$ENGINE" == "semgrep" ]; then
    echo "[1/3] Executando Semgrep (SAST e SCA)..."
    if command -v semgrep &> /dev/null; then
        semgrep ci || fail "Semgrep encontrou vulnerabilidades no código ou dependências!"
    else
        fail "Semgrep não encontrado."
    fi

else
    echo "[1/4] Executando Engine Nativa: Verificando dependências Python (SCA - pip-audit)..."
    if command -v pip-audit &> /dev/null; then
        pip-audit || fail "Vulnerabilidades no pip encontradas!"
    else
        fail "pip-audit não instalado."
    fi

    echo "[1.1/4] Executando Engine Nativa: Verificando dependências Python (SCA - safety)..."
    if command -v safety &> /dev/null; then
        safety check || fail "Vulnerabilidades encontradas pelo safety!"
    else
        warn "safety não instalado. Pulando checagem complementar de SCA."
    fi

    echo "[1.2/4] Executando Engine Nativa: Verificando dependências Node (SCA)..."
    FRONTEND_DIRS=$(find . -maxdepth 2 -name "package.json" -not -path "*/node_modules/*" -exec dirname {} \;)
    if [ -n "$FRONTEND_DIRS" ]; then
        for DIR in $FRONTEND_DIRS; do
            echo "Auditando frontend em: $DIR"
            npm audit --audit-level=high --prefix "$DIR" || fail "Vulnerabilidades graves no npm encontradas em $DIR!"
        done
    fi

    echo "----------------------------------------"
    echo "[2/4] Executando Engine Nativa: Bandit (SAST Python)..."
    if command -v bandit &> /dev/null; then
        TARGET_DIR="."
        for d in app src backend; do
            if [ -d "$d" ]; then
                TARGET_DIR="$d"
                break
            fi
        done
        bandit -r "$TARGET_DIR" -ll -ii || fail "Vulnerabilidades detectadas no código Python!"
    else
        fail "bandit não instalado."
    fi

    echo "----------------------------------------"
    echo "[3/4] Executando Engine Nativa: Checagens estritas e AST Customizado..."

    # Hardening bash grep avoiding pipefail crashes
    set +e
    SECRET_MATCHES=$(grep -rn -i -E "(password|secret|api_key|token).*=.*['\"][a-zA-Z0-9_]{5,}['\"]" --include="*.py" . 2>/dev/null)
    set -e
    if [ -n "$SECRET_MATCHES" ]; then
        if echo "$SECRET_MATCHES" | grep -qvE "(test|example|\.env|config)"; then
            fail "Possíveis senhas/chaves hardcoded encontradas no código!"
        fi
    fi

    set +e
    TOKEN_MATCHES=$(grep -rn -E "(localStorage|sessionStorage)\.setItem\(['\"](token|access_token|auth_token)['\"]" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" . 2>/dev/null)
    set -e
    if [ -n "$TOKEN_MATCHES" ]; then
        fail "Uso de localStorage/sessionStorage para armazenar tokens! Use cookies HttpOnly."
    fi

    python3 -c '
import sys, os, ast, re

exit_code = 0

class SecurityASTVisitor(ast.NodeVisitor):
    def __init__(self, filepath):
        self.filepath = filepath
        self.ssrf_found = False
        self.cors_wildcard_found = False
        self.auth_missing = False
        self.path_traversal_found = False
        self.http_aliases = {"requests", "httpx"}
        self.http_instances = set()
        self.bad_cors_variables = set()
        self.secured_routers = set()

    def visit_Import(self, node):
        for alias in node.names:
            if alias.name in ["requests", "httpx"]:
                self.http_aliases.add(alias.asname or alias.name)
        self.generic_visit(node)

    def visit_ImportFrom(self, node):
        if node.module in ["requests", "httpx", "urllib.request"]:
            for alias in node.names:
                self.http_aliases.add(alias.asname or alias.name)
        self.generic_visit(node)

    def visit_Assign(self, node):
        # Tracker para APIRouter(dependencies=[Depends(...)])
        if isinstance(node.value, ast.Call) and getattr(node.value.func, "id", "") in ["APIRouter", "FastAPI"]:
            for kw in node.value.keywords:
                if kw.arg == "dependencies" and isinstance(kw.value, ast.List):
                    for elt in kw.value.elts:
                        if isinstance(elt, ast.Call) and getattr(elt.func, "id", "") == "Depends":
                            for target in node.targets:
                                if isinstance(target, ast.Name):
                                    self.secured_routers.add(target.id)

        # Tracker heurístico para client = httpx.Client()
        if isinstance(node.value, ast.Call):
            if isinstance(node.value.func, ast.Attribute) and isinstance(node.value.func.value, ast.Name):
                if node.value.func.value.id in self.http_aliases and node.value.func.attr in ["Client", "AsyncClient", "Session"]:
                    for target in node.targets:
                        if isinstance(target, ast.Name):
                            self.http_instances.add(target.id)
        
        # Tracker para CORS: origins = ["*"]
        if isinstance(node.value, ast.List):
            for elt in node.value.elts:
                if isinstance(elt, ast.Constant) and elt.value == "*":
                    for target in node.targets:
                        if isinstance(target, ast.Name):
                            self.bad_cors_variables.add(target.id)
                            
        self.generic_visit(node)

    def visit_Call(self, node):
        # 1. SSRF Semântico e Data-Flow Básico
        if isinstance(node.func, ast.Attribute):
            if isinstance(node.func.value, ast.Name):
                module_name = node.func.value.id
                method_name = node.func.attr
                if (module_name in self.http_aliases or module_name in self.http_instances) and method_name in ["get", "post", "put", "delete", "request"]:
                    print(f"🚨 FALHA: {self.filepath}:{node.lineno} -> SSRF Semântico. Chamada a {module_name}.{method_name}() detectada via Alias/Tracker.")
                    self.ssrf_found = True
        elif isinstance(node.func, ast.Name):
            if node.func.id in ["urlopen", "ClientSession"] or node.func.id in self.http_aliases:
                print(f"🚨 FALHA: {self.filepath}:{node.lineno} -> SSRF Semântico. Chamada direta a {node.func.id}() detectada.")
                self.ssrf_found = True

        # 2. CORS Semântico com suporte a variáveis e Regex
        # NOTA: O FastAPI suporta allow_origin_regex legitimamente. O script aplica uma política conservadora do projeto de bloquear '.*'.
        cors_kwargs = []
        if isinstance(node.func, ast.Attribute) and node.func.attr == "add_middleware":
            if node.args and isinstance(node.args[0], ast.Name) and node.args[0].id == "CORSMiddleware":
                cors_kwargs = node.keywords
        elif isinstance(node.func, ast.Name) and node.func.id == "CORSMiddleware":
            cors_kwargs = node.keywords

        for kw in cors_kwargs:
            if kw.arg == "allow_origins":
                if isinstance(kw.value, ast.List):
                    for elt in kw.value.elts:
                        if isinstance(elt, ast.Constant) and elt.value == "*":
                            print(f"🚨 FALHA: {self.filepath}:{node.lineno} -> CORS Wildcard \"*\" detectado em lista.")
                            self.cors_wildcard_found = True
                elif isinstance(kw.value, ast.Name):
                    if kw.value.id in self.bad_cors_variables:
                        print(f"🚨 FALHA: {self.filepath}:{node.lineno} -> CORS Wildcard \"*\" detectado via variável {kw.value.id}.")
                        self.cors_wildcard_found = True
            elif kw.arg == "allow_origin_regex":
                if isinstance(kw.value, ast.Constant) and ".*" in str(kw.value):
                    print(f"🚨 FALHA: {self.filepath}:{node.lineno} -> CORS Wildcard regex muito permissivo (.*) [Política Conservadora].")
                    self.cors_wildcard_found = True

        # 3. Path Traversal: detecta uso inseguro de .startswith() para validação de caminhos
        if isinstance(node.func, ast.Attribute) and node.func.attr == "startswith":
            # Heurística: se o contexto contiver nomes relacionados a path/file/dir, é suspeito
            if isinstance(node.func.value, ast.Name):
                var_name = node.func.value.id.lower()
                if any(hint in var_name for hint in ["path", "file", "dir", "target", "dest", "resolved"]):
                    print(f"⚠️ AVISO: {self.filepath}:{node.lineno} -> Uso de .startswith() para validação de caminho ({node.func.value.id}). Prefira os.path.commonpath() para evitar bypass por prefixo (ex: /srv/storage-evil).")
                    self.path_traversal_found = True

        self.generic_visit(node)

    def visit_FunctionDef(self, node):
        # SSRF: 1-level interprocedural analysis (detecta functions que envelopam requests)
        for stmt in node.body:
            for child in ast.walk(stmt):
                if isinstance(child, ast.Call):
                    if isinstance(child.func, ast.Attribute) and getattr(child.func.value, "id", "") in self.http_aliases and getattr(child.func, "attr", "") in ["get", "post"]:
                        self.http_aliases.add(node.name) # wrapper function mapped!

        self.check_route_auth(node)
        self.generic_visit(node)

    def visit_AsyncFunctionDef(self, node):
        for stmt in node.body:
            for child in ast.walk(stmt):
                if isinstance(child, ast.Call):
                    if isinstance(child.func, ast.Attribute) and getattr(child.func.value, "id", "") in self.http_aliases and getattr(child.func, "attr", "") in ["get", "post"]:
                        self.http_aliases.add(node.name)

        self.check_route_auth(node)
        self.generic_visit(node)

    def check_route_auth(self, node):
        is_route = False
        verb = ""
        route_decorator = None
        
        for dec in node.decorator_list:
            if isinstance(dec, ast.Call) and isinstance(dec.func, ast.Attribute):
                verb = getattr(dec.func, "attr", "").lower()
                if verb in ("get", "post", "put", "delete", "patch", "api_route"):
                    is_route = True
                    route_decorator = dec
                    
                    # Checa se o roteador desta rota foi marcado como seguro na atribuição
                    if isinstance(dec.func.value, ast.Name) and dec.func.value.id in self.secured_routers:
                        return # Rota segura herdada do router!
                    break
        
        if not is_route:
            return

        has_auth = False
        
        for default in node.args.defaults + getattr(node.args, "kw_defaults", []):
            if default and isinstance(default, ast.Call) and getattr(default.func, "id", "") == "Depends":
                if default.args and isinstance(default.args[0], ast.Attribute):
                    if getattr(default.args[0], "attr", "") == "get_current_user":
                        has_auth = True
                elif default.args and getattr(default.args[0], "id", "") in ["get_current_user", "get_current_active_user", "verify_token"]:
                    has_auth = True
                    
        if route_decorator:
            for kw in route_decorator.keywords:
                if kw.arg == "dependencies" and isinstance(kw.value, ast.List):
                    for elt in kw.value.elts:
                        if isinstance(elt, ast.Call) and getattr(elt.func, "id", "") == "Depends":
                            has_auth = True

        docstring = ast.get_docstring(node)
        if not has_auth and docstring and re.search(r"^PUBLIC_ROUTE:\s+\S.+$", docstring, re.MULTILINE):
            if verb in ("post", "put", "delete", "patch"):
                print(f"🚨 FALHA CRÍTICA: {self.filepath}:{node.lineno} -> Rota \"{node.name}\" tenta usar PUBLIC_ROUTE num método {verb.upper()} destrutivo.")
                self.auth_missing = True
            return

        if not has_auth:
            print(f"🚨 FALHA: {self.filepath}:{node.lineno} -> Rota \"{node.name}\" desprotegida (Política: Exige Depends(get_current_user) ou dependencies=[]).")
            self.auth_missing = True

for root, _, files in os.walk("."):
    parts = set(root.split(os.sep))
    if any(p in parts for p in [".git", "node_modules", "env", "venv", ".venv", "venv_sec", "__pycache__"]):
        continue

    for file in files:
        if file.endswith(".py"):
            filepath = os.path.join(root, file)
            try:
                with open(filepath, "r", encoding="utf-8", errors="strict") as f:
                    content = f.read()
                tree = ast.parse(content)
            except SyntaxError as e:
                print(f"🚨 FALHA CRÍTICA: Erro de sintaxe (SyntaxError) em {filepath}:{e.lineno}.")
                exit_code = 1
                continue
            except Exception as e:
                print(f"🚨 FALHA CRÍTICA: Falha inesperada ao ler/parsear {filepath}: {e}")
                exit_code = 1
                continue
            
            visitor = SecurityASTVisitor(filepath)
            visitor.visit(tree)
            
            if visitor.ssrf_found or visitor.cors_wildcard_found or visitor.auth_missing or visitor.path_traversal_found:
                exit_code = 1

sys.exit(exit_code)
' || fail "Auditoria semântica (AST) falhou!"
fi

echo "----------------------------------------"
if [ $EXIT_CODE -ne 0 ]; then
    echo -e "❌ AUDITORIA FALHOU ($ENGINE). Corrija as falhas acima."
    exit $EXIT_CODE
else
    echo -e "✅ Auditoria concluída com sucesso ($ENGINE)."
    exit 0
fi

