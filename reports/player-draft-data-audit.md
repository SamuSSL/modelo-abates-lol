# Auditoria de jogadores e drafts

## Resultado

Os dados-alvo de 2022 a 2026 possuem 12.316 mapas após a exclusão
auditada da partida interrompida. Todos os mapas têm dez linhas de
jogador, dez jogadores, dez campeões e as cinco posições canônicas.

Foram encontrados três registros sem `playerid`: dois de Pasamelcelo,
na UB pela LES, e um de Noah, na ES pela LFL. Nome, equipe, posição e
campeão permanecem disponíveis. O sistema usa nome e posição como
chave substituta para pesquisa, mas a V1 deve emitir alerta objetivo
quando o identificador oficial estiver ausente.

## Cobertura de campeões

Há 170 campeões observados nos dados-alvo. A taxonomia estática de 2026
contém 173 e cobre todos os campeões históricos.

## Taxonomia

A versão `2026-static-v1` usa o Data Dragon 16.14.1 da Riot. Ela contém
somente papéis e notas oficiais de ataque, defesa, magia e dificuldade.
Esses atributos são aplicados igualmente a 2022–2026. Não há versões
de rework.

Resultados competitivos de 2026 não foram usados para descrever
campeões no passado. Isso impediria uma avaliação temporal honesta.

## Consequência para o modelo

Jogadores são representados por médias anteriores à série, com
decaimento de 60 dias e regressão à média por liga e posição. O draft
é resumido por poucos sinais transparentes. Cada bloco será mantido
somente se melhorar CRPS e calibração fora da amostra.
