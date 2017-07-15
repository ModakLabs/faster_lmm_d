/*
   This code is part of faster_lmm_d and published under the GPLv3
   License (see LICENSE.txt)

   Copyright © 2017 Prasun Anand & Pjotr Prins
*/

module test.pheno_generator;

import std.conv;
import std.random;
import std.stdio;

void generate_pheno_file(string[] args)
{
  writeln("# Phenotype format version 1.0");
  writeln("# Individuals = 1219");
  writeln("# Phenotypes = 1");
  writeln("\t 1");
  Random gen;
  int side = to!int(args[1]) + 1;
  int ignore = uniform(1,side);
  for(int i = 1; i < side ; i++){
    if(i == ignore){continue;}
    write(i);
    write("\t");
    write(uniform(-1.0, 2.0, gen));
    write("\n");
  }
}
