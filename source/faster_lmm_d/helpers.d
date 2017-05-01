/*
   This code is part of faster_lmm_d and published under the GPLv3
   License (see LICENSE.txt)

   Copyright © 2017 Prasun Anand & Pjotr Prins
*/

module faster_lmm_d.helpers;

import std.math : isNaN, pow;

double modDiff(const double x, const double y){
  double rem = y - x;
  if(rem<0){return -rem;}
  return rem;
}

bool[] isnan(const double[] vector){
  bool[] result;
  foreach(element; vector){
    result ~= isNaN(element);
  }
  return result;
}

bool[] negateBool(const bool[] vector){
  bool[] result;
  foreach(element; vector){
    result ~= true - element;
  }
  return result;
}

double sum(const double[] vector){
  double result = 0;
  foreach(element;vector){result+=element;}
  return result;
}

int sum(const bool[] vector){
  int result = 0;
  foreach(element;vector){
    if(element == true){
      result +=1;
    }
  }
  return result;
}

double globalMean(const double[] input){
  return sum(input)/input.length;
}

double getVariation(const double[] vector, const double mean){
  double result = 0;
  foreach(element;vector){result+= pow(element-mean,2);}
  return result/vector.length;
}

double[] getNumArray(const double[] arr, const bool[] valuesArr){
  double[] result = new double[sum(valuesArr)];
  for(int k = 0, index = 0 ; k < arr.length; k++){
    if(valuesArr[k] == true){
      result[index] = arr[k];
      index++;
    }
  }
  return result;
}

void replaceNaN(ref double[] arr, const bool[] valuesArr, const double mean){
  int index = 0;
  foreach(ref element; valuesArr){
    if(element == true){
      index++;
    }else{
      arr[index] = mean;
      index++;
    }
  }
}

double[] rangeArray(const int count){
  double[] arr;
  for(int i = 0; i < count; i++){
    arr ~= i;
  }
  return arr;
}

unittest{
  double[] arr = [4,3,4,5];
  bool[] arr2 = [true, false, true, true];

  assert(sum(arr) == 16);
  assert(sum(arr2) == 3);
  assert(globalMean(arr) == 4);
}
