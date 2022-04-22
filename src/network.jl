using StaticArrays
using LinearAlgebra
using Flux
using BSON: @save, @load

"""
function energyGradients(descriptor, model)

Computes all gradients of energy with respect
to all parameters in the given network
Assumes that the last layer does not contain bias parameters
"""
function computeEnergyGradients(descriptor, model)
    energyGradients = []
    # Compute energy gradients
    gs = gradient(neuralenergy, descriptor, model)
    # Loop over the gradients and collect them in the array
    nlayers = length(model)
    # Structure: gs[2][1][layerId][1 - weigths; 2 - biases]
    for (layerId, layerGradients) in enumerate(gs[2][1]) 
        if layerId != nlayers
            weightGradients = layerGradients[1]
            append!(energyGradients, [weightGradients])
            biasGradients = layerGradients[2]
            append!(energyGradients, [biasGradients])
        else
            weightGradients = layerGradients[1]
            append!(energyGradients, [weightGradients])
        end
    end
    return(energyGradients)
end

"""
function computeCrossCorrelation(descriptor, energyGradients)

Computes cross products of the descriptor and energy gradients
"""
function computeCrossCorrelation(descriptor, energyGradients)
    crossCorrelations = []
    for gradient in energyGradients
        cross = descriptor * gradient[:]' # Matrix Nbins x Nparameters
        append!(crossCorrelations, [cross])
    end
    return(crossCorrelations)
end

"""
function crossAccumulatorsInit(parameters)

Initialize cross correlation accumulator arrays
"""
function crossAccumulatorsInit(parameters)
    crossAccumulators = []
    nlayers = length(parameters.neurons)
    for layerId in 2:nlayers
        if layerId < nlayers
            append!(crossAccumulators, [zeros(Float32, (parameters.Nbins, 
                    parameters.neurons[layerId - 1] * parameters.neurons[layerId]))])
            append!(crossAccumulators, [zeros(Float32, (parameters.Nbins, 
                    parameters.neurons[layerId]))])
        else
            append!(crossAccumulators, [zeros(Float32, (parameters.Nbins, 
                    parameters.neurons[layerId - 1] * parameters.neurons[layerId]))])
        end
    end
    return(crossAccumulators)
end

"""
function updateCrossAccumulators(crossAccumulators, descriptor, model)

Updates cross accumulators by performing element-wise summation
of the cross accumulators with the new cross correlation data
"""
function updateCrossAccumulators!(crossAccumulators, descriptor, model)
    energyGradients = computeEnergyGradients(descriptor, model)
    newCrossCorrelations = computeCrossCorrelation(descriptor, energyGradients)
    for (cross, newCross) in zip(crossAccumulators, newCrossCorrelations)
        cross .+= newCross
    end
    return(crossAccumulators)
end

"""
function computeEnsembleCorrelation(descriptor, model)

Computes correlations of the ensemble averages of the descriptor
and the energy gradients
"""
function computeEnsembleCorrelation(descriptor, model)
    energyGradients = computeEnergyGradients(descriptor, model)
    ensembleCorrelations = computeCrossCorrelation(descriptor, energyGradients)
    return(ensembleCorrelations)
end

"""
function computeDescriptorGradients(crossAccumulators, ensembleCorrelations, parameters)

Computes the gradients of the descriptor with respect to the network parameters
"""
function computeDescriptorGradients(crossAccumulators, ensembleCorrelations, parameters)
    descriptorGradients = []
    for (accumulator, ensemble) in zip(crossAccumulators, ensembleCorrelations)
        gradients = -Float32(parameters.β) .* (accumulator - ensemble)
        append!(descriptorGradients, [gradients])
    end
    return(descriptorGradients)
end

function computeLossGradients(crossAccumulators, descriptorNN, descriptorref, model, parameters)
    lossGradients = []
    ensembleCorrelations = computeEnsembleCorrelation(descriptorNN, model)
    descriptorGradients = computeDescriptorGradients(crossAccumulators, ensembleCorrelations, parameters)
    # Compute derivative of loss with respect to the descriptor
    dLdS = zeros(Float32, length(descriptorNN))
    for i in 1:length(dLdS)
        dLdS[i] = 2*(descriptorNN[i] - descriptorref[i])
    end
    for (gradient, parameters) in zip(descriptorGradients, params(model))
        lossGradient = dLdS' * gradient
        lossGradient = reshape(lossGradient, size(parameters))
        append!(lossGradients, [lossGradient])
    end
    return(lossGradients)
end

"""
function updatemodel!(model, opt, lossGradients)

Updates the network parameters
"""
function updatemodel!(model, opt, lossGradients)
    for (gradient, parameters) in zip(lossGradients, params(model))
        Flux.Optimise.update!(opt, parameters, gradient)
    end
    return
end

"""
function loss(descriptorNN, descriptorref)

Compute the error function
"""
function loss(descriptorNN, descriptorref)
    loss = zeros(length(descriptorNN))
    for i in 1:length(loss)
        loss[i] = (descriptorNN[i] - descriptorref[i])^2
    end
    totalLoss = sum(loss)
    println("Loss = ", round(totalLoss, digits=8))
    return(totalLoss)
end

"""
function buildNetwork!(parameters)

Combines input arguments for neural network building
Note: updates parameters.neurons
"""
function buildNetwork!(parameters)
    if parameters.neurons == [0]
        parameters.neurons = []
    end
    # Add input and output layers to the parameters.neurons
    pushfirst!(parameters.neurons, parameters.Nbins)
    push!(parameters.neurons, 1)
    nlayers = length(parameters.neurons)
    network = []
    for layerId in 2:nlayers
        if layerId < nlayers
        append!(network, [(parameters.neurons[layerId - 1], parameters.neurons[layerId],
                getfield(Main, Symbol(parameters.activation)))])
        else
            append!(network, [(parameters.neurons[layerId - 1], parameters.neurons[layerId])])
        end
    end
    return(network)
end

"""
function buildchain(args...)

Build a multilayered neural network
"""
function buildchain(args...)
    nlayers = length(args)
    layers = []
    for (layerId, arg) in enumerate(args)
        if layerId < nlayers
            layer = Dense(arg...)
        else
            layer = Dense(arg..., bias=false)
        end
        append!(layers, [layer])
    end
    model = Chain(layers...)
    return(model)
end

"""
function mindistance(descriptor, parameters)

Returns the minimal occuring distance in the descriptor
"""
function mindistance(descriptor, parameters)
    for i in 1:parameters.Nbins
        if descriptor[i] != 0
            return((i - 1) * parameters.binWidth)
        end
    end
end

"""
function repulsion(descriptor, parameters)

Returns repulsion weights for the neural network
Functional form for repulsion: stiffness*[exp(-alpha*r)-shift]
alpha is a coefficient that makes sure that the repulsion term
goes to zero at minimal distance from the given pair correlation function (descriptor)
"""
function repulsion(descriptor, parameters)
    bins = [bin*parameters.binWidth for bin in 1:parameters.Nbins]
    minDistance = mindistance(descriptor, parameters)
    # Find alpha so that [exp(-alpha*r) - shift] goes to zero at minDistance
    alpha = -log(parameters.shift)/minDistance
    potential = zeros(Float32, parameters.Nbins)
    for i in 1:parameters.Nbins
        if bins[i] < minDistance
            potential[i] = parameters.stiffness*(exp(-alpha*bins[i])-parameters.shift)
        end
    end
    return(potential)
end

"""
function modelInit(descriptor, parameters)

Generates a neural network with or without repulsion term in the input layer.
If parameters.paramsInit is set to repulsion then the repulsion terms are applied 
for each set of weights associated with a single neuron in the next layer.
Weights in all the other layers are set to unity.
Otherwise all the weights are set to random and biases to zero
"""
function modelInit(descriptor, parameters)
    println("Running ML-IMC in the training mode.\n")
    # Build initial model
    network = buildNetwork!(parameters)
    println("Building a model...")
    model = buildchain(network...)
    println(model)
    println("   Number of layers: $(length(parameters.neurons)) ")
    println("   Number of neurons in each layer: $(parameters.neurons)")
    println("   Parameter initialization: $(parameters.paramsInit)")
    if parameters.paramsInit == "repulsion"
        nlayers = length(model.layers)
        # Initialize weights
        for (layerId, layer) in enumerate(model.layers)
            for column in eachrow(layer.weight)
                Flux.Optimise.update!(column, column)
                if layerId == 1
                    Flux.Optimise.update!(column, -repulsion(descriptor, parameters))
                elseif layerId < nlayers
                    Flux.Optimise.update!(column, -ones(Float32, length(column)))
                else
                    # Multiply the weights by the fraction of input neurons and second-to-last neurons
                    # Migth be useful for many-layered networks, multiplier of unity is ok for one hidden layer 
                    #weightMultiplier = network[1][1] / network[end][1]  
                    weightMultiplier = 1
                    Flux.Optimise.update!(column, -weightMultiplier * ones(Float32, length(column)))
                end
            end
        end
    end
    return(model)
end

"""
function optInit(parameters)

Initializes the optimizer
"""
function optInit(parameters)
    if parameters.optimizer == "Momentum"
        opt = Momentum(parameters.rate, parameters.momentum)
    elseif parameters.optimizer == "Descent"
        opt = Descent(parameters.rate)
    else
        opt = Descent(parameters.rate)
        println("Other types of optimizers are currently not supported!")
    end
    return(opt)
end

"""
function train!(parameters, confs, model, opt, refconfs, descriptorref, rng_xor)

Runs the Machine Learning enhanced Inverse Monte Carlo (ML-IMC) training iterations
"""
function train!(parameters, confs, model, opt, refconfs, descriptorref, rng_xor)
    # Initialize the list of loss values
    losses = []
    # Run training iterations
    iteration = 1
    while iteration <= parameters.iters
        iterString = lpad(iteration, 2, '0')
        println("Iteration $(iteration)...")
        inputs = [(confs[rand(rng_xor, 1:length(confs))], parameters, model) 
                for worker in workers()]
     
        # Run the simulation in parallel
        outputs = pmap(mcsample!, inputs)

        pairdescriptorNN = mean([output[1] for output in outputs])
        energies = mean([output[2] for output in outputs])
        crossAccumulators = mean([output[3] for output in outputs])
        meanAcceptanceRatio = mean([output[4] for output in outputs])

        println("Mean acceptance ratio = ", round(meanAcceptanceRatio, digits=4))

        # Compute loss
        lossvalue = loss(pairdescriptorNN, descriptorref)
        append!(losses, lossvalue)

        # Update the model or revert and update the learning rate
        if iteration > 1
            if losses[iteration] < losses[iteration - 1]
                # Write the descriptor and compute the gradients
                writedescriptor("descriptorNN-iter-$(iterString).dat", pairdescriptorNN, parameters)
                lossGradients = computeLossGradients(crossAccumulators, pairdescriptorNN, descriptorref, model, parameters)

                # Write averaged energies
                writeenergies("energies-iter-$(iterString).dat", energies, parameters, 10)

                # Write the model (before training!)
                @save "model-iter-$(iterString).bson" model

                # Update the model if the loss decreased
                println("The loss has decreased, updating the model...")
                updatemodel!(model, opt, lossGradients)
                # Move on to the next iteration
                iteration += 1
            else
                # Future note: save the cross accumulators in a file, read it instead of rerunning the iteration!
                println("The loss has increased, reverting to the previous model...")
                println("Repeating iteration $((iteration - 1))...")
                # Load the previous model
                prevIterString = lpad((iteration - 1), 2, '0')
                @load "model-iter-$(prevIterString).bson" model
                # Reduce the rate and reinitialize the optimizer
                println("Multiplying the learning rate by $(parameters.rateAdjust) and reinitializing the optimizer...")
                parameters.rate *= parameters.rateAdjust
                println("Learning rate: $(parameters.rate)")
                opt = optInit(parameters)
                # Remove the last loss values
                deleteat!(losses, iteration)
                # Rerun the iteration
                iteration -= 1
            end
        else
            # Write the descriptor and compute the gradients
            writedescriptor("descriptorNN-iter-$(iterString).dat", pairdescriptorNN, parameters)
            lossGradients = computeLossGradients(crossAccumulators, pairdescriptorNN, descriptorref, model, parameters)

            # Write averaged energies
            writeenergies("energies-iter-$(iterString).dat", energies, parameters, 10)

            # Write the model (before training!)
            @save "model-iter-$(iterString).bson" model

            # Update the model if the loss decreased
            updatemodel!(model, opt, lossGradients)
            # Move on to the next iteration
            iteration += 1
        end 

        # Load the reference configurations
        confs = copy(refconfs)
    end
    return
end