# Comparação estrutural e bayesiana

## Escopo

A seleção usou 7.586 mapas distribuídos em nove folds trimestrais de
2023–2025. O histórico começa em 2022. Nenhum resultado de 2026 participou da
escolha de features, priors, transformações, hiperparâmetros ou modelo.

Depois do congelamento, 1.693 mapas de 2026 foram usados somente como comparação
secundária. A confirmação limpa exige mapas posteriores a
2026-07-22 20:02:30 UTC.

## Resultado principal nos folds

| Modelo | CRPS | Log Score | Cobertura 90% | Decisão |
|---|---:|---:|---:|---|
| PCA + Negative Binomial | 4,5571 | 3,4905 | 91,39% | Challenger |
| V1 reconstruído | 4,5622 | 3,4924 | 91,73% | Referência mantida |
| Interação jogador–campeão | 4,5660 | 3,4928 | 90,90% | Não promove |
| Arquétipos funcionais | 4,5718 | 3,4942 | 91,29% | Não promove |
| Equipe e adversário explícitos | 4,5823 | 3,4970 | 91,38% | Rejeita |
| XGBoost | 4,5866 | 3,5107 | 87,38% | Rejeita |
| Intensidade × duração log-normal | 4,6139 | 3,5098 | 89,03% | Rejeita |
| Intensidade × duração Gamma | 4,6152 | 3,5088 | 89,15% | Rejeita |
| QCut | 4,6644 | 3,5158 | 89,89% | Rejeita |
| Bayes hierárquico | 4,7515 | 3,5950 | 97,94% | Rejeita |

A PCA melhorou o CRPS em 0,0050, cerca de 0,11%. O intervalo bootstrap da
diferença contra o V1 foi de -0,0219 a 0,0121. Como o intervalo inclui melhora
e piora, o ganho não é confiável. A PCA venceu em seis folds, mas piorou nos
dois primeiros folds de 2025 e em CBLOL, LCK e LES.

## O que as variáveis mostraram

O sinal mais consistente continua sendo o ritmo recente das equipes. No Bayes,
o coeficiente padronizado de intensidade equipe–adversário foi 0,091 com desvio
posterior de 0,033. O histórico de duração também apresentou sinal positivo,
mas menor: 0,019 com desvio 0,013.

Os efeitos específicos de ataque da equipe e exposição do adversário existiram,
mas foram pequenos depois do pooling. Seus desvios entre equipes ficaram perto
de 0,024 e 0,027 na escala log.

Engage, dive, skirmish e os demais arquétipos tiveram distribuições posteriores
largas ao redor de zero. A interação jogador–campeão também ficou incerta:
coeficiente 0,016 com desvio 0,021. Com o shrinkage equivalente a 30 jogos, ela
não trouxe ganho fora da amostra.

A primeira componente da PCA separou composições de dive, skirmish e engage de
composições de poke e scaling. A segunda componente foi dominada pelo ritmo.
Isso sugere que a PCA reduz redundância entre os scores, mas não prova que criou
um sinal novo.

## Por que o Bayes perdeu

O MCMC funcionou. Todos os nove folds tiveram zero divergências, zero
tree-depth hits e R-hat máximo abaixo de 1,01. Portanto, aumentar iterações não
é a correção principal.

O modelo ficou largo demais. A cobertura nominal de 90% chegou a 97,94%. Ele
somou incerteza da duração, ataque da equipe, exposição do adversário e duas
contagens de kills simuladas separadamente. Essa estrutura gerou variância
excessiva e piorou CRPS e Log Score.

O próximo Bayes, se for testado, deve simplificar a distribuição conjunta. As
alternativas justificadas pelos resultados são:

1. modelar diretamente a intensidade total e usar efeitos de equipe como
   desvios menores;
2. ligar as kills das duas equipes por um fator latente comum, evitando tratá-las
   como independentes;
3. usar uma duração prevista mais calibrada antes de propagá-la ao total;
4. manter somente ritmo e duração como sinais fortes, deixando taxonomia e
   interação em ablação.

## Comparação secundária de 2026

| Modelo | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| PCA + Negative Binomial | 4,4928 | 3,4836 | 90,73% |
| V1 reconstruído | 4,4975 | 3,4838 | 90,37% |
| Bayes hierárquico | 4,7361 | 3,6170 | 98,94% |

A PCA repetiu uma melhora pequena. Isso não altera a seleção, pois 2026 é um
período secundário já conhecido. O V1 permanece a referência até a avaliação
prospectiva posterior ao cutoff.

## Limitação da taxonomia

A taxonomia cobre 173 campeões e vinte atributos funcionais. Ela foi derivada
por regras determinísticas aplicadas às descrições oficiais dos kits. Isso é
reproduzível e não usa resultados futuros, mas ainda não equivale a uma revisão
especialista campeão por campeão. Força de lane, janelas de poder e dependência
de snowball são especialmente difíceis de inferir apenas pelo texto do kit.
Por isso, a ausência de ganho atual não encerra a hipótese de draft; ela rejeita
esta versão automática da taxonomia.
