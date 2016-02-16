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

export Solver, SolverParameters, SolverState, LRPolicy, MomPolicy, solve, SGD,
    get_learning_rate, get_momentum, update
abstract Solver

type SolverState
    iter :: Int
    obj_val :: LatteFloat
    learning_rate :: LatteFloat
    momentum :: LatteFloat
end

abstract LearningRatePolicy
module LRPolicy
using ..Latte.LearningRatePolicy
import ..Latte.LatteFloat
type Fixed <: LearningRatePolicy
    base_lr :: LatteFloat
end

# base_lr * gamma ^ (floor(iter / stepsize))
type Step <: LearningRatePolicy
    base_lr  :: LatteFloat
    gamma    :: LatteFloat
    stepsize :: Int
end

# base_lr * gamma ^ iter
type Exp <: LearningRatePolicy
    base_lr :: LatteFloat
    gamma   :: LatteFloat
end

type Inv <: LearningRatePolicy
    base_lr :: LatteFloat
    gamma   :: LatteFloat
    power   :: LatteFloat
end
end # module LRPolicy

get_learning_rate(policy::LRPolicy.Fixed, state::SolverState) = policy.base_lr
get_learning_rate(policy::LRPolicy.Step, state::SolverState) =
    policy.base_lr * policy.gamma ^ (floor(state.iter / policy.stepsize))
get_learning_rate(policy::LRPolicy.Exp, state::SolverState) =
    policy.base_lr * policy.gamma ^ state.iter
get_learning_rate(policy::LRPolicy.Inv, state::SolverState) =
    policy.base_lr * (1 + policy.gamma * state.iter) ^ (-policy.power)

abstract MomentumPolicy
module MomPolicy
import ..Latte.LatteFloat
using ..Latte.MomentumPolicy
type Fixed <: MomentumPolicy
  base_mom :: LatteFloat
end

# min(base_mom * gamma ^ (floor(iter / stepsize)), max_mom)
type Step <: MomentumPolicy
    base_mom :: LatteFloat
    gamma    :: LatteFloat
    stepsize :: Int
    max_mom  :: LatteFloat
end

type Linear <: MomentumPolicy
    base_mom :: LatteFloat
    gamma    :: LatteFloat
    stepsize :: Int
    max_mom  :: LatteFloat
end
end # module MomPolicy

get_momentum(policy::MomPolicy.Fixed, state::SolverState) = policy.base_mom
get_momentum(policy::MomPolicy.Step, state::SolverState) =
    min(policy.base_mom * policy.gamma ^ (floor(state.iter / policy.stepsize)), policy.max_mom)
get_momentum(policy::MomPolicy.Linear, state::SolverState) =
    min(policy.base_mom + floor(state.iter / policy.stepsize) * policy.gamma, policy.max_mom)


type SolverParameters
    lr_policy::LearningRatePolicy
    mom_policy::MomentumPolicy
    max_itr::Int
    regu_coef::LatteFloat
    test_every::Int
end

type SGD <: Solver
    params :: SolverParameters
    state  :: SolverState
    SGD(params::SolverParameters) = new(params, SolverState(0, 0.0, 0.0, 0.0))
end

function update(sgd::SGD, net::Net)
    for param in net.params
        sgd_update(sgd.state.learning_rate * param.learning_rate,
                   sgd.state.momentum, param.value, param.gradient, param.hist)
    end
end

@eval function update_chunk(sgd::SGD, net::Net)
    # Sync gradients
    for i in length(net.params):-1:1
        param = net.params[i]
        ccall((:wait, $libComm), Void, (Cint,), param.request)
        sgd_update(sgd.state.learning_rate * param.learning_rate,
                   sgd.state.momentum, param.value, param.gradient, param.hist)
    end
end

function sgd_update{T}(learning_rate::AbstractFloat, momentum::LatteFloat,
                       param::Array{T}, gradient::Array{T}, hist::Array{T})
    momentum = convert(T, momentum)
    learning_rate = convert(T, learning_rate)
    # We use BLAS here because the array notation in the comments does not work
    # with current julia, it creates a copy of param and does not increment the
    # array in place

    # hist *= momentum
    BLAS.scal!(length(hist), momentum, pointer(hist), 1)
    BLAS.axpy!(length(hist), learning_rate, pointer(gradient), 1,
               pointer(hist), 1)
    # param -= hist
    BLAS.axpy!(length(hist), convert(T, -1), pointer(hist), 1, pointer(param), 1)
end

function clip_gradients(sgd::SGD, net::Net)
    for param in net.params
        if param.clip_gradients < 0.0f0
            return
        end
        sumsq = 0.0
        for param in net.params
            sumsq += dot(param.gradient[:], param.gradient[:])
        end
        l2norm_diff = sqrt(sumsq)
        if l2norm_diff > param.clip_gradients
            scale = param.clip_gradients / l2norm_diff
            for param in net.params
                BLAS.scal!(length(param.gradient), scale, pointer(param.gradient), 1)
            end
        end
    end
end

function regularize(sgd::SGD, net::Net)
    for param in net.params
        l2_regularization(sgd.params.regu_coef * param.regu_coef, param.value, param.gradient)
    end
end

function l2_regularization(regu_coef::LatteFloat, param::Array, gradient::Array)
    BLAS.axpy!(length(param), convert(eltype(param), 2.0 * regu_coef), pointer(param), 1, pointer(gradient), 1)
end

function solve(solver::Solver, net::Net)
    init(net)
    try
        get_buffer(net, :accuracyvalue)
    catch KeyError
        error("Net must contain an accuracy layer")
    end
    try
        get_buffer(net, :lossvalue)
    catch KeyError
        error("Net must contain a loss layer")
    end

    solver.state.learning_rate = get_learning_rate(solver.params.lr_policy,
                                                   solver.state)
    solver.state.momentum = get_momentum(solver.params.mom_policy,
                                         solver.state)
    if LATTE_MPI
        broadcast_initial_params(net)
    end
    info("Entering solve loop")
    while solver.state.iter < solver.params.max_itr
        solver.state.iter += 1
        forward(net)
        backward(net)

        solver.state.obj_val = get_buffer(net, :lossvalue)[1]
        solver.state.learning_rate = get_learning_rate(solver.params.lr_policy, solver.state)
        solver.state.momentum = get_momentum(solver.params.mom_policy, solver.state)
        clip_gradients(solver, net)
        regularize(solver, net)

        if LATTE_MPI
            update_chunk(solver, net)
        else
            update(solver, net)
        end
        update_rand(net)
        clear_values(net)
        clear_∇(net)
        if solver.state.iter % 20 == 0
            info("Iter $(solver.state.iter) - Loss: $(solver.state.obj_val)")
        end
        if solver.state.iter % solver.params.test_every == 0
            info("Iter $(solver.state.iter) - Testing... (Current train epoch: $(net.train_epoch))")
            acc = test(net)
            if LATTE_MPI
                total_acc = @eval ccall((:reduce_accuracy, $libComm), Cfloat, (Cfloat,), $acc)
                if total_acc >= 0.0f0
                    info("Iter $(solver.state.iter) - Test Result: $total_acc%")
                end
            else
                info("Iter $(solver.state.iter) - Test Result: $acc%")
            end
        end
    end
end