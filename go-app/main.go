// =============================================================================
// Servidor HTTP — http-server-projeto-korp (com Monitoramento Prometheus)
// =============================================================================
//
// ATUALIZAÇÃO FASE 3: Adicionamos instrumentação de métricas.
//
// CONCEITO: "Instrumentação" é o ato de colocar "sensores" no código.
// Assim como um carro tem sensores de velocidade, temperatura e combustível,
// nosso servidor agora tem sensores que medem:
//   - Quantas requisições recebeu (counter)
//   - Quanto tempo cada requisição demorou (histogram)
//   - Se o serviço está vivo (health endpoint)
//
// O Prometheus vem a cada 15 segundos, lê esses sensores (endpoint /metrics),
// e armazena os valores para consulta posterior no Grafana.
// =============================================================================

package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	// -------------------------------------------------------------------------
	// NOVA DEPENDÊNCIA: Biblioteca do Prometheus para Go
	//
	// CONCEITO: Até agora usamos APENAS a stdlib (biblioteca padrão).
	// Agora precisamos de uma biblioteca EXTERNA — a oficial do Prometheus.
	//
	// "promauto" = cria métricas automaticamente (registra no collector global)
	// "promhttp" = handler HTTP que expõe as métricas no formato Prometheus
	//
	// TRADEOFF: Adicionar dependência externa vs implementar do zero?
	//   → A biblioteca oficial é mantida pela mesma equipe do Prometheus.
	//   → Implementar do zero seria reinventar a roda e propenso a bugs.
	//   → Em Go, é comum usar poucas dependências, mas esta é essencial.
	// -------------------------------------------------------------------------
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// =============================================================================
// STRUCT de resposta (mesma da Fase 0)
// =============================================================================

type ProjetoKorpResponse struct {
	Nome    string `json:"nome"`
	Horario string `json:"horario"`
}

// =============================================================================
// MÉTRICAS PROMETHEUS
// =============================================================================
//
// CONCEITO: Definimos as métricas como variáveis GLOBAIS porque:
//   1. Precisam existir durante toda a vida do programa
//   2. São compartilhadas entre todas as requisições
//   3. O Prometheus lê elas a qualquer momento (thread-safe)
//
// Cada métrica tem:
//   - Name: nome único (convenção: prefixo_tipo_unidade)
//   - Help: descrição legível por humanos
//   - Labels: "tags" que permitem filtrar (ex: por método, por rota, por status)
// =============================================================================

var (
	// -------------------------------------------------------------------------
	// COUNTER: http_requests_total
	// -------------------------------------------------------------------------
	//
	// CONCEITO: Counter é como a quilometragem do carro — SÓ SOBE.
	// Conta o TOTAL de requisições desde que o servidor iniciou.
	//
	// Labels (etiquetas):
	//   - method: GET, POST, etc.
	//   - path: /projeto-korp, /health, etc.
	//   - status: 200, 404, 500, etc.
	//
	// Com labels, podemos perguntar ao Prometheus:
	//   "Quantos GET em /projeto-korp retornaram 200?" → filtra por labels
	//   "Quantos requests tiveram status 500?" → filtra só por status
	// -------------------------------------------------------------------------
	httpRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total de requisições HTTP recebidas",
		},
		[]string{"method", "path", "status"},
	)

	// -------------------------------------------------------------------------
	// HISTOGRAM: http_request_duration_seconds
	// -------------------------------------------------------------------------
	//
	// CONCEITO: Histogram distribui valores em "baldes" (buckets).
	// Ao invés de guardar CADA tempo individual, ele conta:
	//   "Quantas requisições levaram < 10ms? E < 50ms? E < 100ms?"
	//
	// Isso permite calcular percentis (p50, p95, p99):
	//   p50 = metade das requests levou MENOS que X ms
	//   p95 = 95% das requests levou MENOS que X ms
	//   p99 = 99% das requests levou MENOS que X ms
	//
	// POR QUE IMPORTA: Se o p99 é 2 segundos, significa que 1 em cada
	// 100 usuários espera 2 segundos. Se você tem 10.000 requests/min,
	// são 100 usuários por minuto tendo experiência ruim.
	//
	// Buckets personalizados: definimos faixas de tempo que fazem sentido
	// para nossa aplicação (de 5ms a 10s). Os defaults do Prometheus
	// são genéricos demais.
	// -------------------------------------------------------------------------
	httpRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name: "http_request_duration_seconds",
			Help: "Duração das requisições HTTP em segundos",
			Buckets: []float64{
				0.005, // 5ms   — resposta instantânea
				0.01,  // 10ms  — muito rápido
				0.025, // 25ms  — rápido
				0.05,  // 50ms  — aceitável
				0.1,   // 100ms — limite do "percepção de instantâneo"
				0.25,  // 250ms — começando a ficar lento
				0.5,   // 500ms — meio segundo, perceptível
				1.0,   // 1s    — lento
				2.5,   // 2.5s  — muito lento
				5.0,   // 5s    — problemático
				10.0,  // 10s   — timeout na maioria dos clients
			},
		},
		[]string{"method", "path"},
	)
)

// =============================================================================
// MIDDLEWARE: instrumentMetrics
// =============================================================================
//
// CONCEITO: Middleware é como um "filtro" que intercepta TODA requisição
// ANTES e DEPOIS de chegar no handler real.
//
// Analogia: Catraca do metrô.
//   → Toda pessoa (request) passa pela catraca (middleware) antes de
//     entrar na estação (handler).
//   → A catraca pode contar pessoas, verificar bilhetes, medir fluxo.
//   → A pessoa nem percebe — a catraca é transparente.
//
// Nosso middleware:
//   1. Anota a hora de início (antes de processar)
//   2. Deixa o handler processar normalmente
//   3. Anota a hora de término (depois de processar)
//   4. Calcula a duração e registra nas métricas
//
// "func(next http.Handler) http.Handler" = função que recebe um handler
// e retorna um NOVO handler que "envolve" o original.
// =============================================================================

func instrumentMetrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now() // Marca o início

		// ---------------------------------------------------------------
		// responseWriter "wrapper" — captura o status code
		//
		// CONCEITO: O http.ResponseWriter padrão do Go não nos deixa
		// VER qual status code foi escrito (200? 404? 500?).
		// Criamos um "wrapper" que intercepta o WriteHeader() e anota.
		//
		// É como colocar um espelho atrás do garçom para ver o que
		// ele escreveu no pedido.
		// ---------------------------------------------------------------
		rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}

		// Chama o handler REAL (ex: handleProjetoKorp)
		next.ServeHTTP(rw, r)

		// Calcula a duração e registra nas métricas
		duration := time.Since(start).Seconds()

		// Registra no counter (incrementa +1)
		httpRequestsTotal.WithLabelValues(
			r.Method,                          // "GET"
			r.URL.Path,                        // "/projeto-korp"
			http.StatusText(rw.statusCode),    // "OK" (200)
		).Inc()

		// Registra no histogram (observa a duração)
		httpRequestDuration.WithLabelValues(
			r.Method,
			r.URL.Path,
		).Observe(duration)
	})
}

// =============================================================================
// responseWriter wrapper — captura o status code HTTP
// =============================================================================
//
// CONCEITO: Implementa a interface http.ResponseWriter, mas adiciona
// a capacidade de "lembrar" qual status code foi enviado.
//
// Em Go, uma "interface" é um contrato: "se você tem estes métodos,
// você é deste tipo". http.ResponseWriter exige:
//   - Header() → retorna os headers
//   - Write() → escreve o body
//   - WriteHeader() → define o status code (200, 404, etc.)
//
// Nosso wrapper herda tudo do original (embedding) e só sobrescreve
// o WriteHeader para anotar o status code.
// =============================================================================

type responseWriter struct {
	http.ResponseWriter           // "Herda" todos os métodos do ResponseWriter original
	statusCode          int       // Campo extra para guardar o status code
	written             bool      // Evita registrar mais de uma vez
}

func (rw *responseWriter) WriteHeader(code int) {
	if !rw.written {
		rw.statusCode = code
		rw.written = true
	}
	rw.ResponseWriter.WriteHeader(code) // Chama o WriteHeader REAL
}

// =============================================================================
// FUNÇÃO MAIN
// =============================================================================

func main() {
	mux := http.NewServeMux()

	// Registrar endpoints de negócio
	mux.HandleFunc("GET /projeto-korp", handleProjetoKorp)
	mux.HandleFunc("GET /health", handleHealth)

	// -------------------------------------------------------------------------
	// NOVO: Endpoint /metrics (Prometheus)
	//
	// CONCEITO: promhttp.Handler() é um handler PRONTO da biblioteca
	// do Prometheus. Quando acessado, ele:
	//   1. Lê TODAS as métricas registradas (nossos counters + histograms)
	//   2. Formata no padrão texto do Prometheus
	//   3. Retorna como resposta HTTP
	//
	// O Prometheus acessa este endpoint a cada 15 segundos (configurável)
	// para "raspar" (scrape) os valores atuais.
	//
	// NOTA: NÃO passamos /metrics pelo middleware de métricas para não
	// criar um loop infinito (o scraping geraria métricas sobre si mesmo).
	// -------------------------------------------------------------------------
	mux.Handle("GET /metrics", promhttp.Handler())

	// -------------------------------------------------------------------------
	// Aplicar middleware de métricas a TODOS os requests
	//
	// CONCEITO: instrumentMetrics "envolve" o mux inteiro.
	// Todo request que chega passa pelo middleware PRIMEIRO,
	// depois vai para o mux (que direciona ao handler correto).
	//
	// Fluxo: Request → Middleware (mede) → Mux → Handler → Resposta
	//                                                    ↓
	//                    Middleware (registra duração) ←←←
	// -------------------------------------------------------------------------
	instrumentedMux := instrumentMetrics(mux)

	server := &http.Server{
		Addr:         ":8080",
		Handler:      instrumentedMux, // Agora usa o mux COM middleware
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	// Graceful shutdown (mesmo da Fase 0)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("Servidor iniciado na porta %s", server.Addr)
		log.Println("Métricas disponíveis em /metrics")
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Erro ao iniciar servidor: %v", err)
		}
	}()

	<-ctx.Done()
	log.Println("Sinal de desligamento recebido, iniciando graceful shutdown...")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Fatalf("Erro durante shutdown: %v", err)
	}

	log.Println("Servidor encerrado com sucesso.")
}

// =============================================================================
// HANDLERS (mesmos da Fase 0, sem alteração)
// =============================================================================

func handleProjetoKorp(w http.ResponseWriter, r *http.Request) {
	response := ProjetoKorpResponse{
		Nome:    "Projeto Korp",
		Horario: time.Now().UTC().Format(time.RFC3339),
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		http.Error(w, "Erro ao gerar resposta JSON", http.StatusInternalServerError)
		log.Printf("Erro ao codificar JSON: %v", err)
	}
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}
