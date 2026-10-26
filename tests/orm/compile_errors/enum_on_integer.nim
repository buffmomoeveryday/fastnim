# expect: enum choices belong on a CharField
import fastnim/orm
type Rank = enum rankLow, rankHigh
model Item:
  rank: IntegerField(choices: Rank)
