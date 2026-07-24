# Amostra mínima de equipe

## Pergunta

Quanto histórico recente cada equipe precisa ter para que o ritmo próprio
adicione informação confiável além da liga?

O estudo comparou `nb_pace` com `nb_league` nos mesmos 7.586 mapas dos nove
folds de 2023–2025. O ano de 2026 permaneceu fechado.

## O que é um jogo efetivo

Jogo efetivo mede informação recente. Um jogo disputado agora vale 1. Depois de
60 dias vale 0,5. Depois de 120 dias vale 0,25. Os valores de todos os jogos são
somados.

O limite usa a equipe com menor histórico entre as duas. Portanto, uma partida
só passa quando Blue e Red atingem o mínimo.

## Resultado

O menor limite aprovado pela regra pré-registrada foi 1 jogo efetivo por equipe.

| Grupo | Mapas | Diferença de CRPS contra modelo de liga | Intervalo bootstrap 95% | Cobertura 90% |
|---|---:|---:|---:|---:|
| Elegíveis, ambas com 1 ou mais | 7.484 | -0,0710 | -0,0947 a -0,0491 | 91,61% |
| Bloqueados, alguma abaixo de 1 | 102 | -0,0787 | -0,2958 a 0,1276 | 91,18% |

Nos elegíveis, o intervalo inteiro ficou abaixo de zero. Ritmo próprio melhora
a previsão com confiança. Nos bloqueados, o intervalo é largo e cruza zero.
Existem poucos mapas e não há evidência suficiente para confiar no sinal.

O corte retém 98,66% dos mapas e bloqueia 1,34%.

## Ligas

Entre os elegíveis, `nb_pace` superou `nb_league` nas sete ligas:

| Liga | Mapas | Diferença de CRPS |
|---|---:|---:|
| CBLOL | 684 | -0,0494 |
| LCK | 1.522 | -0,0972 |
| LCS | 637 | -0,0143 |
| LEC | 883 | -0,0883 |
| LES | 721 | -0,0754 |
| LFL | 762 | -0,0771 |
| LPL | 2.275 | -0,0657 |

LCS novamente apresenta ganho pequeno, mas não há piora média.

Entre os 102 bloqueados, resultados por liga ficaram misturados. CBLOL, LCS,
LEC e LES pioraram com ritmo; LCK, LFL e LPL melhoraram, mas algumas ligas
possuem somente dois a oito mapas. Isso confirma falta de evidência.

## Por que não exigir 10 ou 20

Limites entre 2 e 15 também separaram grupos, mas a regra escolhe o menor limite
confiável para não bloquear previsões sem necessidade.

A partir do corte 20, até o grupo abaixo do limite já mostrou ganho confiável
do ritmo. Bloquear todos esses mapas descartaria informação útil comprovada.

Contagem bruta foi apenas diagnóstico. Ela não percebe que cem jogos antigos
podem valer pouco hoje. Por isso o gate usa amostra efetiva com decaimento.

## Decisão operacional

Equipe com menos de 1 jogo efetivo de histórico recente bloqueia a previsão:

`Pouca amostra para X. Não apostar.`

O gate foi implementado em `assess_team_sample_eligibility()`. Valor ausente
também bloqueia.

Este limite vale somente para equipes e para o modelo atual. Jogadores e
campeões ainda precisam de estudos próprios antes da inferência pós-draft.
