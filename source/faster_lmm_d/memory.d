module faster_lmm_d.memory;

import core.sys.linux.config;
import core.sys.linux.sys.sysinfo;

import std.stdio;

c_ulong virtual_memory_total(){
  sysinfo_ memInfo;
  sysinfo (&memInfo);
  c_ulong totalVirtualMem = memInfo.totalram;
  totalVirtualMem += memInfo.totalswap;
  totalVirtualMem *= memInfo.mem_unit;
  return totalVirtualMem/(8 * 1024 * 1024);
}

c_ulong virtual_memory_used(){
  sysinfo_ memInfo;
  sysinfo (&memInfo);
  c_ulong virtualMemUsed = memInfo.totalram - memInfo.freeram;
  virtualMemUsed += memInfo.totalswap - memInfo.freeswap;
  virtualMemUsed *= memInfo.mem_unit;
  writeln(virtualMemUsed/(8 * 1024 * 1024));
  return virtualMemUsed/(8 * 1024 * 1024);
}

c_ulong ram_total(){
  sysinfo_ memInfo;
  sysinfo (&memInfo);
  c_ulong totalPhysMem = memInfo.totalram;
  totalPhysMem *= memInfo.mem_unit;
  return totalPhysMem/(8 * 1024 * 1024);
}

c_ulong ram_used(){
  sysinfo_ memInfo;
  sysinfo (&memInfo);
  c_ulong physMemUsed = memInfo.totalram - memInfo.freeram;
  physMemUsed *= memInfo.mem_unit;
  return physMemUsed/(8 * 1024 * 1024);
}

void check_memory(string msg = "check_memory") {
  stderr.writeln(msg);
  auto ram_used  = ram_used();
  auto ram_tot   = ram_total();
  auto vmem_used = virtual_memory_used();
  auto vmem_tot  = virtual_memory_total();
  stderr.writeln("RAM  ",ram_used,"/",ram_tot);
  stderr.writeln("VIRT ",vmem_used,"/",vmem_tot);
}
