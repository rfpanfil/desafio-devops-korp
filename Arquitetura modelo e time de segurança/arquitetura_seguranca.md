# 🏛️ Arquitetura de Segurança Modelo — FastAPI + React

> Documento de referência ("estado da arte") para implementação segura de projetos web.
> Baseado nas vulnerabilidades documentadas pelo [Mano Deyvin](https://manodeyvin.com.br/p/5-vacilacoes-de-seguranca-que-a-ia) e complementado com práticas de OWASP Top 10 e verificações automatizadas em CI/CD.

---

## 📋 Princípio Fundamental: Zero Trust

**Nunca confie no cliente.** Validações de segurança devem ser obrigatórias no backend. Validações no frontend podem existir para UX (ocultar botões, formatar campos), mas nunca reduzem a necessidade das validações server-side (validação mandatória no backend).

```
┌────────────────────────────────────────────────────────────┐
│  FRONTEND (React)                                          │
│  ├── Oculta botões/menus por cargo (UX)          ← NÃO    │
│  │   é segurança                                           │
│  └── Guarda token em HttpOnly Cookie             ← SIM    │
├────────────────────────────────────────────────────────────┤
│  BACKEND (FastAPI)                                         │
│  ├── Negar por padrão (c/ exceções explícitas)   ← SIM    │
│  ├── Autoriza por cargo/permissão (RBAC)         ← SIM    │
│  ├── Isola dados (filtro app + RLS nativo)       ← SIM    │
│  ├── Valida TODO input (tipo, tamanho, formato)  ← SIM    │
│  ├── Nunca expõe secrets no código               ← SIM    │
│  └── Audita ações sensíveis em logs              ← SIM    │
└────────────────────────────────────────────────────────────┘
```

---

## 1. Isolamento de Dados (Filtro de Tenant / RLS)

**Isolamento Forte de Tenants com Múltiplas Camadas:**
A garantia de isolamento não deve depender apenas da memória do desenvolvedor. A arquitetura DEVE exigir:
1. Filtro de tenant na camada de aplicação (ORM).
2. Políticas RLS nativas habilitadas no banco de dados para tabelas sensíveis.
3. Configuração correta do contexto de tenant na conexão/transação (exemplo: via `SET local` em arquiteturas PostgreSQL, ou equivalente para a stack em uso).
4. Testes automatizados que comprovem o isolamento entre tenants.
5. Cuidado extremo com usuários administrativos e rotinas de background.

```python
# ✅ CORRETO — filtra pela empresa do usuário logado
@router.get("/recursos")
def listar(current_user = Depends(get_current_user), db = Depends(get_db)):
    return db.query(Recurso).filter(
        Recurso.empresa_id == current_user.empresa_id
    ).all()
```

---

## 2. Autenticação, Tokens e Gestão de Contas

**Armazenamento de Token (Frontend):**
- **NUNCA** guarde o Access Token ou Refresh Token no `localStorage` ou `sessionStorage`. Qualquer ataque XSS roubará a sessão instantaneamente.
- **Armazenamento Correto:** O backend deve enviar o token como um cookie `HttpOnly`, `Secure` e `SameSite=Strict`.

**Proteção CSRF:**
- Ao usar cookies para sessão, você **DEVE** implementar mitigação contra CSRF através de um padrão reconhecido. **Primeiro, use a proteção CSRF nativa do framework quando disponível** para evitar implementação insegura. Se customizado, prefira *Synchronizer Token Pattern* (se houver estado no servidor) ou *Signed Double-Submit Cookie*. Adicionalmente, exija validação complementar dos headers `Origin` e `Referer` (lembre-se: atrás de proxy reverso, a comparação deve considerar o host alvo correto, analisando headers como `X-Forwarded-Host` **somente quando houver cadeia de proxy confiável e saneamento do cabeçalho na borda**), e considere validar **Fetch Metadata headers** (`Sec-Fetch-Site`, `Sec-Fetch-Mode`) como camada moderna de defesa em profundidade (nota: Fetch Metadata não substitui tokens CSRF nem Origin/Referer, pois sua eficácia depende do suporte do navegador e cliente). Embora `SameSite=Strict` seja uma forte mitigação, ele não resolve todos os cenários (ex: subdomínios, integrações externas). Nenhuma rota GET deve alterar estado.

**Gestão e Revogação de Tokens/Sessões:**
- JWTs Access Tokens devem ter vida curta (ex: 15-60 minutos).
- **Refresh Tokens** devem possuir sistema de revogação/blacklist no backend. Logout deve invalidar o refresh token imediatamente no banco de dados ou Redis.
- Sempre regenere o identificador de sessão (ou emita novos tokens revogando os antigos) após login, elevação de privilégio e recuperação de conta.
- Garanta o cabeçalho `Cache-Control: no-store` para todas as respostas HTTP que contenham conteúdo autenticado ou material de sessão.
- Habilite **HSTS** (`Strict-Transport-Security`) no domínio servido exclusivamente por HTTPS, idealmente de forma consistente em toda a aplicação web (sendo HSTS uma política de host e não apenas de áreas autenticadas).
- **Nunca** aceite identificadores de sessão (*session IDs* ou tokens) via URL ou mecanismos alternativos quando cookies forem o padrão (isso reduz ataque de *fixation* e vazamento em logs/Referrer).

**Account Lockout (Prevenção a Força Bruta / DoS):**
- Aplicar rate limiting progressivo por conta, IP, dispositivo e janela temporal. Evitar lockout permanente ou previsível por conta isoladamente (para mitigar ataques de Denial of Service contra usuários legítimos). Registrar eventos, alertar sobre padrões anômalos e responder sempre de modo genérico a não revelar se a conta existe.

**Logs de Auditoria e Proteção:**
- Todas as ações críticas (mudança de permissões, deleções, login falho) DEVEM ser registradas com correlacionamento via `request_id`.
- Sincronização de tempo (NTP) é obrigatória para garantir a integridade temporal da trilha de auditoria em investigações forenses. Garantir integridade de armazenamento (ex: WORM, append-only, SIEM com retenção imutável ou controles equivalentes).
- Nunca concatenar input não normalizado diretamente em logs. Usar logging estruturado (JSON), com sanitização de quebras de linha para prevenir **Log Injection**.
- Proteja os logs contra vazamentos em *query strings* sensíveis e reflita os erros cuidadosamente para não causar poluição ou vazamento de estado interno.
- Para auditoria de IP, exija uma cadeia de proxies confiáveis antes de aceitar headers como `X-Forwarded-For`.
- **Governança de Dados (PII):** Registre o mínimo necessário, classifique os dados e mascare PII quando preciso. Separe logs de aplicação, auditoria e segurança em índices distintos para aplicar retenções e controles de acesso (RBAC) diferentes. Aplique proteção de acesso operacional rigorosa ao stack de observabilidade.
- Nunca registre tokens, cookies, senhas ou URLs com credenciais embutidas.

---

## 3. Gestão de Secrets e Deploy Seguro

- `.env` no `.gitignore` é obrigatório.
- Exija que as variáveis críticas (`SECRET_KEY`, `DATABASE_URL`) existam e aborte o sistema (fail-fast) se ausentes em produção.
- **Containers e Docker:** 
  - NUNCA rode a aplicação como usuário `root` no Dockerfile. Crie um usuário `appuser`.
  - Em produção (Kubernetes, AWS, Render), não injete senhas via `.env` em texto plano, use o Secret Manager da nuvem.

---

## 4. Validação de Input (Uploads & Rate Limiting)

- **Uploads:** Sempre valide a extensão em uma whitelist estrita, verifique *magic bytes*, imponha limite de MB, e sanitize o nome do arquivo usando um `UUID` aleatório para evitar Path Traversal.
- **Controle Robusto contra SSRF:** O ideal de segurança (Design-Level) é **nunca aceitar uma URL completa do usuário**; se o caso de uso permitir, utilize IDs mapeados, hosts pré-cadastrados no servidor ou templates *server-side*. Se o input de URL externa for estritamente inevitável, aplique as seguintes defesas em profundidade:
  - **Requisitos de Validação:** Rejeite credentials embutidas (*userinfo*) na URL, restrinja o esquema a HTTPS sempre que possível, e valide o destino contra uma allowlist estrita.
  - **Arquitetura (Conexão Efetiva):** A validação do IP DEVE ser rigidamente vinculada à conexão efetiva. Recomendação: conectar ao IP validado e preservar Host/SNI adequadamente, ou utilizar uma arquitetura de egress proxy/fetcher dedicado. Antes da validação contra allowlist, é mandatória uma **normalização canônica estrita**: parse único, rejeição sumária de ambiguidades de parser, resolução DNS controlada e comparação contra a allowlist somente *após* a canonicalização final (repetindo a validação inteira a cada redirect permitido).
  - **Padrão Inseguro Proibido:** Não é suficiente resolver o IP, validar e depois realizar uma nova requisição pelo hostname original via cliente HTTP padrão (gera risco de DNS Rebinding / TOCTOU). Também é proibido repassar a resposta bruta do alvo diretamente ao cliente.
  - **Requisitos Operacionais e Testes:** Desative ou revalide cada redirect. Bloqueie IPs privados, loopback, link-local, metadados cloud, e **rejeite explicitamente _fragments_ (`#`)** (como saneamento robusto de input, útil para parsers internos e clientes não-browser). *Atenção:* mesmo não sendo enviado pelo navegador, o *fragment* pode ser inadvertidamente incluído em headers como `Referer` por bibliotecas HTTP client durante cadeias de redirecionamento no backend; garanta que o cliente HTTP utilizado no fetcher não preserve nem reflita fragments em `Referer` ou outros headers derivados da URL de entrada. Em redes onde for possível ter essa granularidade, bloqueie CGNAT (100.64.0.0/10) e IPs IPv6 ULA / IPv4-mapped variants, além do RFC1918. Imponha limites de `timeout` e tamanho máximo da resposta (bytes). Registre requisições sensíveis com telemetria e utilize egress filtering. **Testes Obrigatórios:** Teste bypasses conhecidos de parser e codificação (ex: IPv6, notações decimal/octal/hex e confusões de parser de URL).

---

## 5. Configurações de Infraestrutura (Security Headers e CORS)

- **Security Headers (CSP Operacional):** Habilite o CSP definindo explicitamente `frame-ancestors` (é o controle moderno preferencial; `X-Frame-Options` pode permanecer por compatibilidade), controlando rigidamente `connect-src`, `img-src`, `font-src` e `script-src`. **Obrigatório em CSP Estrita:** Inclua `object-src 'none'`, `base-uri 'none'` (ou `'self'`) e `form-action 'self'`. Evite `unsafe-eval` e `unsafe-inline` (prefira *nonce* ou *hash*). O CSP deve **preferencialmente ser entregue por Header HTTP** (uso via `<meta>` tag só é aceitável em exceções documentadas, com ciência das limitações). O header CSP deve estar presente em **todas as respostas HTTP relevantes** (ex: HTML principal, páginas de erro, e superfícies renderizadas pelo browser). Nota: `Content-Security-Policy-Report-Only` é exclusivo para a fase de implantação/mapeamento de falsos positivos, e jamais deve ser o estado final permanente.
  - *Exemplo inicial de política:* `default-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none';`. (Nota: aplicações reais precisarão expandir `script-src`, `style-src`, `img-src`, `connect-src` e opcionalmente `report-uri`/`report-to` conforme sua superfície).
- **CORS:** Defina whitelist explícita de origens. **Jamais use `["*"]`** (especialmente crítico se credenciais estiverem habilitadas). Caso utilize `allow_origin_regex`, a regex **DEVE ser ancorada e restritiva**, escapando pontos (ex: `r"^https://([a-z0-9-]+\.)?example\.com$"`). Lembre-se: uma regex correta não salva um subdomínio comprometido, portanto exige-se governança estrita sobre os subdomínios confiados. Uma regex frouxa como `.*` expõe a aplicação massivamente.
- **Resiliência (Banco de Dados):** Em conexões SQLAlchemy, configure `pool_pre_ping=True` para evitar conexões "stale" e falhas operacionais temporárias.

---

## 🚀 Fechando o Ciclo: Automação e Gates de CI/CD

As regras acima são intenções. Para se tornarem realidade, elas devem ser **forçadas automaticamente** pelo pipeline de CI/CD e ganchos locais.

### Day 1 Bootstrap: Checklist para Novos Projetos
Sempre que você criar um projeto novo do zero, execute este scaffold de segurança no "Dia 1":

1. [ ] **Copie o `audit.sh`** para a raiz do repositório.
2. [ ] **Copie o `security-reqs.in` e `security-requirements.txt`** para a raiz do repositório (instale via `pip install --require-hashes -r security-requirements.txt`).
3. [ ] **Copie o `.github/workflows/security.yml`** para habilitar o Security Gate automatizado no CI. Configure apenas `security-gate` como Status Check obrigatório no Branch Protection.
4. [ ] **Copie o `.github/dependabot.yml`** para manter actions e ferramentas de segurança atualizadas automaticamente.
5. [ ] **Copie a pasta `.agents/`** para herdar as skills de desenvolvimento seguro (se utilizar agentes IA).
6. [ ] **Configure o Pre-commit Hook:** Instale o Husky (Node) ou `pre-commit` (Python) para impedir o `git commit` caso o `audit.sh` falhe.
7. [ ] **Copie o `.env.example`** e adicione o `.env` ao `.gitignore`.
8. [ ] **Instale middlewares básicos** de CORS (whitelist) e Security Headers.
