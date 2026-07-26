# Estratégia de testes

## Revisão V1

- Testes de rework e troca de versão histórica ficam desativados para a V1.
- Toda data de 2022–2026 usa a mesma versão estática da taxonomia 2026.
- Fixtures douradas exigem paridade numérica entre inferência R e Python.
- Streamlit terá testes de validação, bloqueio, cálculo de mercado, persistência
  e smoke test local em ambiente Linux compatível.
- Deploy público exige health check visual, URL acessível e predição de exemplo
  sem erro.

## Processo TDD

Para cada unidade de produção:

1. escrever o teste;
2. executar e confirmar falha pela razão esperada;
3. implementar o mínimo;
4. executar o teste focado;
5. refatorar;
6. executar a suíte relacionada;
7. preservar evidência do comando e resultado.

Não será criado código de produção antes da aprovação dos documentos SDD.

## Pirâmide

### Unitários

Funções puras de validação, transformação, cálculo probabilístico, taxonomia, features e métricas.

### Contrato

Schemas de CSV, tabelas canônicas, bundle, API JSON e cliente Python.

### Integração

Fluxos entre ingestão, DuckDB, features, treino, serialização, API e reconciliação.

### Estatísticos

PMF, simulações conhecidas, calibração sintética, recuperação aproximada de parâmetros e diagnósticos.

### Regressão

Fixtures pequenas e snapshots estáveis para bugs já encontrados.

### Reprodutibilidade

Reexecução com seed, restauração `renv`, equivalência entre scripts e `targets`.

## Matriz requisito–teste

| Requisito | Teste principal | Evidência |
|---|---|---|
| PRD-001 | validação de duas equipes, sides e lineups | unitário e API |
| PRD-002 | aceita `.5` e rejeita inteiro, `.25`, `.75`, NA e infinito | unitário |
| PRD-003 | PMF soma 1, média/mediana/intervalo coerentes | estatístico |
| PRD-004 | casos analíticos de odds, EV e no-vig | unitário |
| PRD-005 | entidades abaixo do mínimo retornam `blocked` | unitário e API |
| PRD-006 | warnings não bloqueadores preservam previsão | unitário |
| PRD-007 | draft conhecido, híbrido e taxonomia ausente | unitário e snapshot |
| PRD-008 | duas chamadas criam dois snapshots imutáveis | integração |
| PRD-009 | aposta exige lado e odd, stake fica em 1 | unitário |
| PRD-010 | reconciliação exata, ambígua, void e ausente | integração |
| PRD-011 | mesma seed reproduz PMF e métricas | reprodutibilidade |
| PRD-012 | metadata reflete bundle e catálogos ativos | contrato da API |

## Casos críticos

### Target

- soma correta das duas linhas de equipe;
- não duplicação com deaths;
- divergência entre team kills e jogadores;
- ausência de uma linha de equipe;
- side duplicado;
- remake explícito;
- jogo curto válido não excluído apenas pela duração.

### Schema e identidade

- arquivos 2022–2026 com colunas em ordens distintas;
- coluna renomeada com adapter conhecido;
- schema desconhecido;
- hash divergente;
- ID estável com rebranding;
- alias ambíguo;
- LVP SL para LES;
- LTA North/South e confronto cruzado;
- registro `partial` elegível e inelegível.

### Série e tempo

- mapas da mesma série compartilham cutoff;
- mapa anterior da série não entra em feature;
- evento exatamente no cutoff é excluído;
- treino nunca contém série futura;
- encoding supervisionado é recalculado por fold;
- derivação de série ambígua bloqueia uso.

### Features

- rolling usa apenas passado;
- shrinkage converge ao prior com amostra zero e à estimativa local com amostra alta;
- mudança de equipe e função;
- side correto;
- estabilidade de lineup;
- remoção de patch, playoffs e bans da matriz final;
- feature catalog declara disponibilidade e fonte.

### Taxonomia e draft

- exatamente cinco posições por equipe;
- campeão duplicado;
- campeão sem versão aplicável;
- rework troca a versão;
- scores dentro do domínio;
- primary e secondary determinísticos;
- composição híbrida reduz confiança;
- explicação identifica fatores dominantes;
- pesquisa sem fonte aprovada não entra na configuração ativa.

### Probabilidades

- PMF finita, não negativa e normalizada;
- massa truncada abaixo da tolerância;
- Over diminui quando a linha aumenta;
- Under aumenta quando a linha aumenta;
- Over + Under igual a 1;
- push igual a zero;
- fair odds igual a inverso da probabilidade;
- EV correto para vitória e derrota;
- no-vig normaliza para 1;
- probabilidades extremas não causam divisão silenciosa por zero.

### Modelos

- baseline reproduzível;
- Poisson detecta overdispersion em fixture sintética;
- Negative Binomial recupera sinal sintético;
- pooling parcial encolhe grupo pequeno;
- MCMC falha promoção com divergências ou R-hat inválido;
- boosting não usa validação futura;
- ensemble possui pesos não negativos somando 1;
- serialização preserva previsões;
- bundle rejeitado não pode ser ativado.

### Avaliação

- folds são crescentes e sem sobreposição futura;
- holdout não participa do tuning;
- CRPS conhecido em distribuições simples;
- bootstrap preserva blocos;
- linhas do mesmo mapa não são contadas como independentes;
- métricas por liga reconciliam com o total;
- ablação usa os mesmos mapas;
- candidato pior não é promovido.

### API e persistência

- payload válido;
- campos ausentes e extras incompatíveis;
- nomes ambíguos;
- odds inválidas;
- previsão salva antes da decisão de aposta;
- decisão Over ou Under sem odd correspondente;
- decisão `no_bet` sem stake;
- segunda decisão para a mesma previsão rejeitada;
- bloqueio persiste snapshot sem EV acionável;
- falha de banco impede resposta `ok`;
- timeout do cliente Python;
- duas odds produzem no-vig;
- apenas uma odd não produz no-vig;
- latência abaixo de 30 segundos com bundle carregado.

### Reconciliação

- evento exato;
- horário reagendado com alias;
- múltiplos candidatos;
- remake/void;
- consulta sem aposta não entra em ROI;
- aposta Over e Under com 1 unidade;
- snapshot original permanece imutável.

## Fixtures

Fixtures devem ser pequenas, sintéticas quando possível e sem depender dos CSVs completos. Dados reais mínimos só entram quando redistribuição e licença permitirem; caso contrário, testes constroem registros equivalentes.

Fixtures obrigatórias:

- mapa completo válido;
- mapa `partial` válido;
- inconsistência de target;
- série com três mapas;
- LTA North, South e confronto cruzado;
- rebranding;
- campeão com rework;
- PMFs analíticas;
- snapshots e resultados prospectivos.

## Cobertura

Metas serão por risco:

- cobertura elevada e branch coverage para target, cutoff, PMF, odds, EV, bloqueios e contrato;
- cobertura relevante para adapters, taxonomia, persistência e reconciliação;
- relatórios e wrappers terão smoke tests.

Cobertura total não substitui casos extremos nem testes estatísticos.

## Comandos de verificação previstos

Os comandos definitivos serão registrados após o ambiente R existir. A verificação mínima incluirá:

- suíte focada do módulo;
- suíte completa `testthat`;
- checagem do projeto/pacote;
- execução de scripts com fixtures;
- pipeline `targets` reduzido;
- teste do cliente Python contra API local;
- restauração limpa do `renv`;
- inspeção de arquivos alterados e validação dos documentos.

## Critérios para concluir um milestone

- testes novos foram vistos falhando antes da implementação;
- testes focados e suíte relacionada passam;
- não há warnings estatísticos ignorados;
- documentação e decision log foram atualizados;
- outputs são reproduzíveis;
- nenhuma decisão empírica foi promovida sem evidência.

## Cobertura da rodada de ratings dinâmicos

- todas as equipes permanecem selecionáveis na interface;
- pouca amostra é sinalizada sem esconder a entidade;
- a interface e o payload não exigem jogadores;
- o bundle operacional não contém catálogo nem limite de jogador;
- ratings locais e globais excluem a própria equipe da referência;
- momentum, snowball e agressividade permanecem congelados antes da série;
- Ridge, Lasso e Elastic Net aprendem imputação e `lambda` somente no treino;
- um draft padrão conclui a previsão no teste funcional do Streamlit.
