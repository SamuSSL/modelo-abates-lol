# Relatório do modelo conjunto por equipe e Monte Carlo Histórico

## Pergunta

Testar se decompor o total em expectativas de kills das duas equipes, modelar
duração e dependência e depois simular a distribuição melhora a previsão do
mercado Over/Under.

O desenvolvimento usou apenas mapas anteriores a 2026. Os 1.710 mapas de 2026
foram abertos somente depois do congelamento da rodada.

## Implementação

Foram implementados:

- dois registros dirigidos por mapa, com ataque próprio e exposição adversária;
- efeitos Ridge de equipe e adversário, com fallback para entidades novas;
- intensidade por minuto de cada equipe;
- duração lognormal prevista separadamente;
- Binomial Negativa por equipe e para o total;
- soma independente exata por convolução;
- duração compartilhada;
- total coerente com divisão Beta-Binomial;
- dependência residual por cópula Gaussiana regularizada;
- Monte Carlo Histórico puro com vetores reais pareados;
- Monte Carlo Histórico por vizinhos condicionais;
- Monte Carlo de choques históricos de duração e kills;
- misturas paramétricas e históricas escolhidas somente no treino interno.

Os vetores históricos mantêm juntos duração, kills azuis e kills vermelhas. A
base rejeita qualquer registro cujo cutoff de previsão não seja anterior ao
mapa. Jogadores não entram em nenhuma feature.

## Resultado em desenvolvimento

Foram avaliados 7.586 mapas nos nove folds temporais de 2023–2025.

| Modelo | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| V1 | 4,5622 | 3,4924 | 91,73% |
| Total coerente | 4,5712 | 3,5036 | 93,99% |
| Cópula Gaussiana | 4,5754 | 3,5040 | 94,07% |
| Híbrido condicional | 4,5783 | 3,5331 | 93,36% |
| Soma independente exata | 4,5788 | 3,5072 | 94,61% |
| Duração compartilhada | 4,6340 | 3,5416 | 96,77% |
| Histórico condicional | 4,6789 | 5,1132 | 89,92% |
| Histórico puro | 4,6818 | 4,5250 | 90,65% |
| Choques históricos | 4,8550 | 5,0238 | 96,03% |

O melhor challenger, `coherent_total`, piorou o CRPS em 0,0090. O bootstrap
pareado de blocos temporais produziu intervalo de 95% de -0,0143 a 0,0339.
Portanto, existe incerteza, mas não existe o ganho mínimo pré-registrado.

Na média das linhas testadas, a V1 também teve o menor Brier, 0,14764. O total
coerente obteve 0,14779. O maior erro absoluto de calibração foi 0,51 ponto
percentual na V1 e 3,74 pontos percentuais no total coerente.

## Comparação secundária em 2026

| Modelo | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| V1 | 4,4959 | 3,4836 | 90,41% |
| Total coerente | 4,5025 | 3,4936 | 93,98% |
| Híbrido condicional | 4,5112 | 3,4998 | 93,27% |
| Cópula Gaussiana | 4,5237 | 3,5075 | 94,97% |
| Histórico condicional | 4,6453 | 4,1921 | 90,06% |
| Histórico puro | 4,6619 | 3,9014 | 90,53% |
| Choques históricos | 4,8255 | 6,8668 | 93,80% |

O total coerente piorou o CRPS em 0,0065. O intervalo bootstrap de 95% foi
-0,0280 a 0,0413. Como 2026 já tinha sido consultado antes, esse resultado é
somente diagnóstico.

## Dependência e expectativas das equipes

A correlação residual estimada entre as kills das equipes ficou entre -0,42 e
-0,37 nos folds. Depois do shrinkage, a cópula usou correlações entre -0,31 e
-0,28.

As médias previstas das duas equipes tiveram correlação -0,087 no
desenvolvimento, contra -0,259 nas kills observadas. Isso mostra que parte
importante da dependência continua sendo aleatória ou latente. A cópula melhora
a representação dessa dependência, mas não gerou ganho no total.

## Monte Carlo Histórico

O método puro sorteou mapas reais anteriores da mesma liga, ponderados por
recência. O método condicional acrescentou vizinhos por duração, expectativas
das equipes, margem e participação prevista. O método de choques reaplicou
juntos os percentis históricos de duração e kills às expectativas atuais.

Mesmo preservando caudas e eventos reais, os três métodos perderam informação
condicional e produziram Log Score pior. As misturas reduziram o dano, mas
nenhuma venceu a V1. No caso dos choques, o peso histórico escolhido para 2026
foi zero.

## Convergência numérica

Contra uma referência de 100 mil sorteios, nenhum orçamento até 40 mil cumpriu
simultaneamente a tolerância de 0,25 ponto percentual na probabilidade e 0,005
no CRPS:

| Sorteios | Diferença máxima Over/Under | Diferença média absoluta de CRPS |
|---:|---:|---:|
| 1.000 | 4,99 p.p. | 0,1233 |
| 5.000 | 2,56 p.p. | 0,0529 |
| 10.000 | 1,62 p.p. | 0,0376 |
| 40.000 | 1,11 p.p. | 0,0223 |

O limite de latência foi atendido. O problema foi ruído numérico da PMF
empírica, não tempo de processamento. Onde a solução exata existe, a convolução
continua preferível.

## Decisão

`REJECTED` para promoção. A V1 e o ensemble shadow permanecem inalterados.

A decomposição por equipe é útil para diagnóstico, mas não melhorou a
distribuição do total. Monte Carlo Histórico não deve ser adicionado ao
Streamlit apenas por ser mais intuitivo. A próxima confirmação válida continua
sendo prospectiva, com linhas e odds reais.

Status geral do projeto: `GO WITH CONDITIONS` para pesquisa e coleta
prospectiva; `HOLD` para afirmar vantagem econômica de aposta.
