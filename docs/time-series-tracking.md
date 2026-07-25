# Tracking temporal de ligas e equipes

## Objetivo

O tracking descreve como o ambiente de kills muda ao longo do tempo. Ele serve
para diagnóstico, leitura de contexto e pesquisa. Não altera a V1 por si só.

As séries são semanais e cobrem 2022–2026. Há séries para:

- total de kills, kills por minuto e duração de cada liga;
- ataque, exposição defensiva, ritmo e duração de cada equipe;
- ratings de ataque e defesa, agressividade quando à frente ou atrás e
  snowball de cada equipe.

## Normalização

Cada série compara duas médias móveis exponenciais:

- nível recente: quatro observações semanais;
- padrão: doze observações semanais.

O índice normalizado é o nível recente dividido pelo padrão, multiplicado por
100. Assim:

- 100 significa alinhamento com o padrão;
- acima de 100 significa nível recente acima do padrão;
- abaixo de 100 significa nível recente abaixo do padrão.

Essas janelas usam observações, não dias corridos. Semanas sem jogos não são
inventadas nem preenchidas.

## Indicadores

- Momentum: distância percentual do índice para 100.
- Tendência: inclinação do nível recente nas últimas oito observações,
  expressa como percentual do padrão por semana.
- Volatilidade: desvio-padrão das variações logarítmicas nas últimas oito
  observações.
- Regime: combinação entre posição do índice e direção da tendência.

Os regimes são: equilibrado, quente e acelerando, quente desacelerando, frio e
enfraquecendo, frio recuperando e pouca amostra.

## Controle de vazamento

Os indicadores de cada semana usam apenas o presente e o passado da própria
série. Quando são testados como features de previsão, o mapa recebe somente o
último valor de uma semana completamente anterior ao cutoff da série. A semana
do próprio jogo nunca é usada.

## Resultado como feature preditiva

O challenger Ridge com os indicadores temporais foi pior que o Ridge de
ratings e comportamento:

| Período | Modelo atual | Com séries temporais | Diferença de CRPS |
|---|---:|---:|---:|
| Folds 2022–2025 | 4,5456 | 4,5681 | +0,0225 |
| Comparação secundária 2026 | 4,4717 | 4,4909 | +0,0193 |

Menor CRPS é melhor. No desenvolvimento, a probabilidade bootstrap de o
challenger ser melhor foi 0%. Em 2026, foi 0,7%. Portanto, os indicadores ficam
no painel de diagnóstico e não entram no modelo congelado.

Isso não significa que a leitura temporal seja inútil. Significa apenas que
esta transformação simples não acrescentou poder preditivo ao que o modelo já
sabia por recência, ratings e comportamento.
