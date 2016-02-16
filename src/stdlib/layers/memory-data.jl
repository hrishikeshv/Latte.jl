#=
Copyright (c) 2015, Intel Corporation

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright notice,
      this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Intel Corporation nor the names of its contributors
      may be used to endorse or promote products derived from this software
      without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
=#

export MemoryDataLayer

type MemoryDataEnsemble{N,M} <: DataEnsemble
    name       :: Symbol
    neurons    :: Array{DataNeuron,N}
    value      :: Array{Float32, M}  # M != N because of batch dimension
end

function forward{N}(ens::MemoryDataEnsemble, data::Array{Float32,N}, phase::Phase)
    data[:] = ens.value[:]
end

function backward{N}(ens::MemoryDataEnsemble, data::Array{Float32,N}, phase::Phase)
end

function MemoryDataLayer(net::Net, name::Symbol, shape::Tuple; time_steps=1)
    data_neurons = Array(DataNeuron, shape...)
    for i in 1:length(data_neurons)
        data_neurons[i] = DataNeuron(0.0)
    end
    value = Array(Float32, shape..., batch_size(net))
    ens = MemoryDataEnsemble(name, data_neurons, value)
    add_ensemble(net, ens)
    ens, value
end