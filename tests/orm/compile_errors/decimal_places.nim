# expect: decimalPlaces (4) must be between 0 and maxDigits (2)
import fastnim/orm
model Price:
  amount:
    DecimalField(maxDigits: 2, decimalPlaces: 4)
