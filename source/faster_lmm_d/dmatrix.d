/*
   This code is part of faster_lmm_d and published under the GPLv3
   License (see LICENSE.txt)

   Copyright © 2017 Prasun Anand & Pjotr Prins
*/

module faster_lmm_d.dmatrix;

import std.math;
import std.stdio;
import std.typecons;

alias ulong m_items;

struct dmatrix{
  m_items[] shape; // dimensions are never negative
  double[] elements;
  bool init = false;

  this(const ulong[] s, const double[] e) {
    shape    = s.dup();
    elements = e.dup();
    init     = true;
  }

  const m_items cols() { return shape[0]; }
  const m_items rows() { return shape[1]; }
  const m_items n_pheno() { return cols; }
  const m_items m_geno() { return rows; }
  const bool is_square() { return rows == cols; };

  double acc(ulong row, ulong col) {
    return this.elements[row*this.shape[1]+col];
  }
}

alias Tuple!(dmatrix, "geno", string[], "gnames", immutable(string[]), "ynames") genoObj;

dmatrix logDmatrix(const dmatrix inDmat) {
  double[] elements = new double[inDmat.shape[0] * inDmat.shape[1]];
  for(auto i = 0; i < inDmat.shape[0]*inDmat.shape[1]; i++) {
    elements[i] = log(inDmat.elements[i]);
  }
  return dmatrix(inDmat.shape, elements);
}

dmatrix addDmatrix(const dmatrix lha, const dmatrix rha) {
  assert(lha.shape[0] == rha.shape[0]);
  assert(lha.shape[1] == rha.shape[1]);
  double[] elements = new double[lha.shape[0] * lha.shape[1]];
  for(auto i = 0; i < lha.shape[0]*lha.shape[1]; i++) {
    elements[i] = lha.elements[i] + rha.elements[i];
  }
  return dmatrix(lha.shape, elements);
}

dmatrix subDmatrix(const dmatrix lha, const dmatrix rha) {
  assert(lha.shape[0] == rha.shape[0]);
  assert(lha.shape[1] == rha.shape[1]);
  double[] elements = new double[lha.shape[0] * lha.shape[1]];
  for(auto i = 0; i < lha.shape[0]*lha.shape[1]; i++) {
    elements[i] = lha.elements[i] - rha.elements[i];
  }
  return dmatrix(lha.shape, elements);
}

dmatrix multiplyDmatrix(const dmatrix lha, const dmatrix rha) {
  ulong[] rha_shape = rha.shape.dup;
  if(lha.shape[0] != rha.shape[0]){
    ulong[] temp = rha.shape.dup;
    rha_shape = [temp[1], temp[0]];
  }
  double[] elements = new double[lha.shape[0] * lha.shape[1]];
  if(lha.shape[1] == rha_shape[1]) {
    for(auto i = 0; i < lha.shape[0]*lha.shape[1]; i++) {
      elements[i] = lha.elements[i] * rha.elements[i];
    }
  }
  else{
    for(auto i = 0; i < lha.shape[0]*lha.shape[1]; i++) {
      elements[i] = lha.elements[i] * rha.elements[i%(rha_shape[0]*rha_shape[1])];
    }
  }

  return dmatrix(lha.shape, elements);
}

dmatrix addDmatrixNum(const dmatrix input, const double num) {
  double[] elements = new double[input.shape[0] * input.shape[1]];
  for(auto i = 0; i < input.shape[0]*input.shape[1]; i++) {
    elements[i] = input.elements[i] + num;
  }
  return dmatrix(input.shape, elements);
}

dmatrix subDmatrixNum(const dmatrix input, const double num) {
  double[] elements = new double[input.shape[0] * input.shape[1]];
  for(auto i = 0; i < input.shape[0]*input.shape[1]; i++) {
    elements[i] = input.elements[i] - num;
  }
  return dmatrix(input.shape, elements);
}

dmatrix multiplyDmatrixNum(const dmatrix input, const double num) {
  double[] elements = new double[input.shape[0] * input.shape[1]];
  for(auto i = 0; i < input.shape[0]*input.shape[1]; i++) {
    elements[i] = input.elements[i] * num;
  }
  return dmatrix(input.shape, elements);
}

dmatrix divideNumDmatrix(const double num, const dmatrix input) {
  double[] elements = new double[input.shape[0] * input.shape[1]];
  for(auto i = 0; i < input.shape[0]*input.shape[1]; i++) {
    elements[i] =  num /input.elements[i];
  }
  return dmatrix(input.shape, elements);
}

dmatrix divideDmatrixNum(const dmatrix input, const double factor) {
  double[] elements = new double[input.shape[0] * input.shape[1]];
  for(auto i = 0; i < input.shape[0]*input.shape[1]; i++) {
    elements[i] = input.elements[i]/factor;
  }
  return dmatrix(input.shape, elements);
}

dmatrix zerosMatrix(const ulong rows, const ulong cols) {
  double[] elements = new double[rows * cols];
  for(auto i = 0; i < rows*cols; i++) {
    elements[i] = 0;
  }
  return dmatrix([rows, cols], elements);
}

dmatrix onesMatrix(const ulong rows, const ulong cols) {
  double[] elements = new double[rows * cols];
  for(auto i = 0; i < rows*cols; i++) {
    elements[i] = 1;
  }
  return dmatrix([rows, cols], elements);
}

dmatrix horizontallystack(const dmatrix a, const dmatrix b) {
  auto n = a.shape[0];
  double[] arr;
  for(auto i = 0; i < n; i++) {
    arr ~= a.elements[(a.shape[1]*i)..(a.shape[1]*(i+1))];
    arr ~= b.elements[(b.shape[1]*i)..(b.shape[1]*(i+1))];
  }
  return dmatrix([a.shape[0], a.shape[1]+b.shape[1]], arr);
}

bool[] compareGt(const dmatrix lha, const double val) {
  bool[] result = new bool[lha.shape[0] * lha.shape[1]];
  for(auto i = 0; i < lha.shape[0] * lha.shape[1]; i++) {
    if(lha.elements[i] > val) {
      result[i] = true;
    }
    else{
      result[i] = false;
    }
  }
  return result;
}

bool eqeq(const dmatrix lha, const dmatrix rha) {
  auto index = 0;
  foreach(s; lha.shape) {
    if(s != rha.shape[index]) {
      return false;
    }
    index++;
  }
  index = 0;
  foreach(s; lha.elements) {
    double rem = s -rha.elements[index];
    if(rem < 0) {rem *= -1;}
    if(rem > 0.001) {
      return false;
    }
    index++;
  }
  return true;
}

dmatrix getCol(const dmatrix input, const ulong colNo) {
  double[] arr;
  for(auto i=0; i<input.shape[0]; i++) {
    arr ~= input.elements[i*input.shape[1]+colNo];
  }
  return dmatrix([input.shape[0],1],arr);
}

dmatrix getRow(const dmatrix input, const ulong rowNo) {
  double[] arr = input.elements[rowNo*input.shape[1]..(rowNo+1)*input.shape[1]].dup;
  return dmatrix([1,input.shape[1]],arr);
}


void setCol(ref dmatrix input, const ulong colNo, const dmatrix arr) {
  for(auto i=0; i<input.shape[0]; i++) {
    input.elements[i*input.shape[1]+colNo] = arr.elements[i];
  }
}

void setRow(ref dmatrix input, const ulong rowNo, const dmatrix arr) {
  auto index =  rowNo*input.shape[1];
  auto end =  (rowNo+1)*input.shape[1];
  auto k = 0;
  for(auto i=index; i<end; i++) {
    input.elements[i] = arr.elements[k];
    k++;
  }
}

void nanCounter(const dmatrix input) {
  auto nanCounter = 0;
  foreach(ref ele; input.elements) {
    if(std.math.isNaN(ele)) {
      writeln("Encountered a NaN");
      nanCounter++;
    }
  }
  if(nanCounter>0){
    writefln("NaNs encountered => %d", nanCounter);
  }
}


unittest{
  auto d = dmatrix([2,2],[1,2,3,4]);

  // Test equality of two dmatrixes
  auto lha = dmatrix([3,3], [1,    2, 3, 4, 5, 6, 7, 8, 9]);
  auto rha = dmatrix([3,3], [1.001,2, 3, 4, 5, 6, 7, 8, 9]);
  assert(eqeq(lha, rha));

  // Test the fields of a dmatrix
  assert(d.shape == [2,2]);
  assert(d.elements == [1,2,3,4]);

  // Test elementwise operations
  auto d2 = dmatrix([2,2],[2,4,5,6]);
  auto d3 = dmatrix([2,2],[3,6,8,10]);
  assert(addDmatrix(d, d2) == d3);
  assert(addDmatrixNum(d, 0) == d);

  assert(subDmatrix(d3, d2) == d);
  assert(subDmatrixNum(d, 0) == d);

  auto d4 = dmatrix([2,2],[6,24,40,60]);
  assert(multiplyDmatrix(d2,d3) == d4);
  assert(multiplyDmatrixNum(d2,1) == d2);

  assert(divideDmatrixNum(d2,1) == d2);

  auto zeroMat = dmatrix([3,3], [0,0,0, 0,0,0, 0,0,0]);
  assert(zerosMatrix(3,3) == zeroMat);

  auto onesMat = dmatrix([3,3], [1,1,1, 1,1,1, 1,1,1]);
  assert(onesMatrix(3,3) == onesMat);

  auto colMatrix = dmatrix([2,1], [2,4]);
  assert( getCol(d, 1) == colMatrix );

  auto rowMatrix = dmatrix([1,2], [3,4]);
  assert( getRow(d, 1) == rowMatrix );

  auto row = dmatrix([1,2], [3.5,4.2]);
  setRow(d, 1, row);
  auto newD =  dmatrix([2,2], [1, 2, 3.5, 4.2]);
  assert( d == newD );

  auto left = dmatrix([3, 1], [1,
                               4,
                               5]);

  auto right = dmatrix([3, 2], [2, 4,
                                4, 8,
                                7, 12]);

  auto stacked = dmatrix([3, 3], [1, 2, 4,
                                  4, 4, 8,
                                  5, 7, 12]);
  assert(horizontallystack(left, right) == stacked);
}
